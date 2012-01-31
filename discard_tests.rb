require 'config'
require 'lib/dm'
require 'lib/log'
require 'lib/utils'
require 'lib/fs'
require 'lib/status'
require 'lib/tags'
require 'lib/thinp-test'
require 'lib/xml_format'

#----------------------------------------------------------------

class DiscardTests < ThinpTestCase
  include Tags
  include Utils
  include XMLFormat

  def read_metadata
    dump_metadata(@metadata_dev) do |xml_path|
      File.open(xml_path, 'r') do |io|
        read_xml(io)            # this is the return value
      end
    end
  end

  def with_dev_md(md, thin_id, &block)
    md.devices.each do |dev|
      next unless dev.dev_id == thin_id

      return block.call(dev)
    end
  end

  def assert_no_mappings(md, thin_id)
    with_dev_md(md, thin_id) do |dev|
      assert_equal(0, dev.mapped_blocks)
      assert_equal([], dev.mappings)
    end
  end

  def assert_fully_mapped(md, thin_id)
    with_dev_md(md, thin_id) do |dev|
      assert_equal(div_up(@volume_size, @data_block_size), dev.mapped_blocks)
    end
  end

  # The block should be a predicate that says whether a given block
  # should be provisioned.
  def check_provisioned_blocks(md, thin_id, size, &block)
    provisioned_blocks = Array.new(size, false)

    with_dev_md(md, thin_id) do |dev|
      dev.mappings.each do |m|
        m.origin_begin.upto(m.origin_begin + m.length - 1) do |b|
          provisioned_blocks[b] = true
        end
      end
    end

    0.upto(size - 1) do |b|
      assert_equal(block.call(b), provisioned_blocks[b],
                   "bad provision status for block #{b}")
    end
  end

  def assert_used_blocks(pool, count)
    status = PoolStatus.new(pool)
    assert_equal(status.used_data_blocks, count)
  end

  def test_discard_empty_device
    with_standard_pool(@size) do |pool|
      with_new_thin(pool, @volume_size, 0) do |thin|
        thin.discard(0, @volume_size)
        assert_used_blocks(pool, 0)
      end
    end

    md = read_metadata
    assert_no_mappings(md, 0)
  end

  def test_discard_fully_provisioned_device
    blocks_per_dev = div_up(@volume_size, @data_block_size)

    with_standard_pool(@size) do |pool|
      with_new_thins(pool, @volume_size, 0, 1) do |thin, thin2|
        wipe_device(thin)
        wipe_device(thin2)
        assert_used_blocks(pool, 2 * blocks_per_dev)
        thin.discard(0, @volume_size)
        assert_used_blocks(pool, blocks_per_dev)
      end
    end

    md = read_metadata
    assert_no_mappings(md, 0)
    assert_fully_mapped(md, 1)
  end

  def test_discard_single_block
    @data_block_size = 128
    blocks_per_dev = div_up(@volume_size, @data_block_size)

    with_standard_pool(@size) do |pool|
      with_new_thin(pool, @volume_size, 0) do |thin|
        wipe_device(thin)
        assert_used_blocks(pool, blocks_per_dev)
        thin.discard(0, @data_block_size)
        assert_used_blocks(pool, blocks_per_dev - 1)
      end
    end

    md = read_metadata
    check_provisioned_blocks(md, 0, div_up(@volume_size, @data_block_size)) do |b|
      b == 0 ? false : true
    end
  end

  def test_discard_partial_blocks
    @data_block_size = 128
    with_standard_pool(@size) do |pool|
      with_new_thin(pool, @volume_size, 0) do |thin|
        wipe_device(thin)

        thin.discard(0, 127)
        thin.discard(63, 159)
      end
    end

    md = read_metadata
    assert_fully_mapped(md, 0)
  end

  def test_discard_alternate_blocks
    @data_block_size = 128
    nr_blocks = div_up(@volume_size, @data_block_size)

    with_standard_pool(@size) do |pool|
      with_new_thin(pool, @volume_size, 0) do |thin|
        wipe_device(thin)

        b = 0
        while b < nr_blocks
          thin.discard(b * @data_block_size, @data_block_size)
          b += 2
        end
      end
    end

    md = read_metadata
    check_provisioned_blocks(md, 0, nr_blocks) {|b| b.odd?}
  end
end
