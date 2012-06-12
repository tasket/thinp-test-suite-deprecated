require 'lib/benchmarking'
require 'lib/bufio'
require 'lib/log'
require 'lib/prerequisites-checker'
require 'lib/process'
require 'lib/tvm'
require 'lib/utils'

#----------------------------------------------------------------

$prereqs = Prerequisites.requirements do
  require_in_path('thin_check',
                  'thin_dump',
                  'thin_restore',
                  'dt',
                  'blktrace',
                  'bonnie++')
  require_ruby_version /^1.8/
end

module ThinpTestMixin
  include Benchmarking
  include ProcessControl
  include TinyVolumeManager

  def setup
    check_prereqs

    config = Config.get_config
    @metadata_dev = config[:metadata_dev]
    @data_dev = config[:data_dev]

    @data_block_size = config[:data_block_size]
    @data_block_size = 128 if @data_block_size.nil?

    @size = config[:data_size]
    @size = 20971520 if @size.nil?
    @size /= @data_block_size
    @size *= @data_block_size

    @volume_size = config[:volume_size]
    @volume_size = 2097152 if @volume_size.nil?

    @tiny_size = @data_block_size

    @low_water_mark = config[:low_water_mark]
    @low_water_mark = 5 if @low_water_mark.nil?

    @mass_fs_tests_parallel_runs = config[:mass_fs_tests_parallel_runs]
    @mass_fs_tests_parallel_runs = 128 if @mass_fs_tests_parallel_runs.nil?

    @dm = DMInterface.new

    @bufio = BufIOParams.new
    @bufio.set_param('peak_allocated_bytes', 0)

    wipe_device(@metadata_dev, 8)
  end

  def teardown
    info("Peak bufio allocation was #{@bufio.get_param('peak_allocated_bytes')}")
  end

  def limit_metadata_dev_size(size)
    max_size = 8355840
    size = max_size if size > max_size
    size
  end

  def dflt(h, k, d)
    h.member?(k) ? h[k] : d
  end

  def with_standard_pool(size, opts = Hash.new)
    zero = dflt(opts, :zero, true)
    discard = dflt(opts, :discard, true)
    discard_pass = dflt(opts, :discard_passdown, true)
    read_only = dflt(opts, :read_only, false)

    table = Table.new(ThinPool.new(size, @metadata_dev, @data_dev,
                                   @data_block_size, @low_water_mark,
                                   zero, discard, discard_pass, read_only))

    @dm.with_dev(table) do |pool|
      yield(pool)
    end
  end

  def with_standard_cache()
    # we set up a small linear device, made out of the metadata dev.
    # That is at most a 16th the size of the data dev.
    tvm = VM.new
    md_size = dev_size(@metadata_dev)
    tvm.add_allocation_volume(@metadata_dev, 0, md_size)
    
    tvm.add_volume(linear_vol('cache', [md_size, round_up(@size / 16, @data_block_size)].min))
    with_dev(tvm.table('cache')) do |cache|
      table = Table.new(Cache.new(dev_size(@data_dev), @data_dev, cache, @data_block_size))
      with_dev(table) {|cached_dev| yield(cached_dev)}
    end
  end

  def with_standard_linear()
    table = Table.new(Linear.new(@size, @data_dev, 0))
    with_dev(table) {|linear| yield(linear)}
  end

  def with_dev(table, &block)
    @dm.with_dev(table, &block)
  end

  def with_devs(*tables, &block)
    @dm.with_devs(*tables, &block)
  end

  def with_thin(pool, size, id, opts = Hash.new)
    @dm.with_dev(Table.new(Thin.new(size, pool, id, opts[:origin]))) do |thin|
      yield(thin)
    end
  end

  def with_new_thin(pool, size, id, opts = Hash.new, &block)
    pool.message(0, "create_thin #{id}")
    with_thin(pool, size, id, opts, &block)
  end

  def with_thins(pool, size, *ids, &block)
    tables = ids.map {|id| Table.new(Thin.new(size, pool, id))}
    @dm.with_devs(*tables, &block)
  end

  def with_new_thins(pool, size, *ids, &block)
    ids.each do |id|
      pool.message(0, "create_thin #{id}")
    end

    with_thins(pool, size, *ids, &block)
  end

  def with_new_snap(pool, size, id, origin, thin = nil, &block)
    if thin.nil?
        pool.message(0, "create_snap #{id} #{origin}")
        with_thin(pool, size, id, &block)
    else
      thin.pause do
        pool.message(0, "create_snap #{id} #{origin}")
      end
      with_thin(pool, size, id, &block)
    end
  end

  def in_parallel(*ary, &block)
    threads = Array.new
    ary.each do |entry|
      threads << Thread.new(entry) do |e|
        block.call(e)
      end
    end

    threads.each {|t| t.join}
  end

  def assert_bad_table(table)
    assert_raise(ExitError) do
      @dm.with_dev(table) do |pool|
      end
    end
  end

  def with_mounts(fs, mount_points)
    if fs.length != mount_points.length
      raise "number of filesystems differs from number of mount points"
    end

    mounted = Array.new

    teardown = lambda do
      mounted.each {|fs| fs.umount}
    end

    bracket_(teardown) do
      0.upto(fs.length - 1) do |i|
        fs[i].mount(mount_points[i])
        mounted << fs[i]
      end

      yield
    end
  end

  def trans_id(pool)
    PoolStatus.new(pool).transaction_id
  end

  def set_trans_id(pool, old, new)
    pool.message(0, "set_transaction_id #{old} #{new}")
  end

  def count_deferred_ios(&block)
    b = get_deferred_io_count
    block.call
    get_deferred_io_count - b
  end

  def assert_identical_files(f1, f2)
    begin
      ProcessControl::run("diff -bu #{f1} #{f2}")
    rescue
      flunk("files differ #{f1} #{f2}")
    end
  end

  # Reads the metadata from an _inactive_ pool
  def dump_metadata(dev, held_root = nil)
    metadata = nil
    held_root_arg = held_root ? "-m #{held_root}" : ''
    Utils::with_temp_file('metadata_xml') do |file|
      ProcessControl::run("thin_dump #{held_root_arg} #{dev} > #{file.path}")
      file.rewind
      yield(file.path)
    end
  end

  def restore_metadata(xml_path, dev)
    ProcessControl::run("thin_restore -i #{xml_path} -o #{dev}")
  end

  def read_held_root(pool, dev)
    metadata = nil

    status = PoolStatus.new(pool)
    Utils::with_temp_file('metadata_xml') do |file|
      ProcessControl::run("thin_dump -m #{status.held_root} #{dev} > #{file.path}")
      file.rewind
      metadata = read_xml(file)
    end

    metadata
  end

  def read_metadata(dev)
    metadata = nil

    Utils::with_temp_file('metadata_xml') do |file|
      ProcessControl::run("thin_dump #{dev} > #{file.path}")
      file.rewind
      metadata = read_xml(file)
    end

    metadata
  end

  def reload_with_error_target(dev)
    dev.pause do
      dev.load(Table.new(Error.new(dev.active_table.size)))
    end
  end

  private
  def get_deferred_io_count
    ProcessControl.run("cat /sys/module/dm_thin_pool/parameters/deferred_io_count").to_i
  end

  def check_prereqs
    begin
      $prereqs.check
    rescue => e
      STDERR.puts e
      STDERR.puts "Missing prerequisites, please see the README"
      exit(1)
    end
  end
end

#----------------------------------------------------------------