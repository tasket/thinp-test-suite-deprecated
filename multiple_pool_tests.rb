require 'config'
require 'lib/dm'
require 'lib/log'
require 'lib/process'
require 'lib/utils'
require 'lib/thinp-test'

#----------------------------------------------------------------

class MultiplePoolTests < ThinpTestCase
  include Utils
  include TinyVolumeManager

  def test_two_pools_pointing_to_the_same_metadata_fails
    assert_raises(RuntimeError) do
      with_standard_pool(@size) do |pool1|
        with_standard_pool(@size) do |pool2|
          # shouldn't get here
        end
      end
    end
  end

  def test_two_pools_can_create_thins
    # carve up the data device into two metadata volumes and two data
    # volumes.
    tvm = VM.new
    tvm.add_allocation_volume(@data_dev, 0, dev_size(@data_dev))

    md_size = tvm.free_space / 16
    1.upto(2) do |i|
      tvm.add_volume(VolumeDescription.new("md_#{i}", md_size))
    end

    block_size = 128
    data_size = (tvm.free_space / 8) / block_size * block_size
    1.upto(2) do |i|
      tvm.add_volume(VolumeDescription.new("data_#{i}", data_size))
    end

    # Activate.  We need a component that automates this from a
    # description of the system.
    with_devs(tvm.table('md_1'),
              tvm.table('md_2'),
              tvm.table('data_1'),
              tvm.table('data_2')) do |md_1, md_2, data_1, data_2|

      # zero the metadata so we get a fresh pool
      wipe_device(md_1, 8)
      wipe_device(md_2, 8)

      with_devs(Table.new(ThinPool.new(data_size, md_1, data_1, 128, 0)),
                Table.new(ThinPool.new(data_size, md_2, data_2, 128, 0))) do |pool1, pool2|

        with_new_thin(pool1, data_size, 0) do |thin1|
          with_new_thin(pool2, data_size, 0) do |thin2|
            in_parallel(thin1, thin2) {|t| dt_device(t)}
          end
        end
      end
    end
  end

  # creates a pool on dev, and creates as big a thin as possible on
  # that
  def with_pool_volume(dev, max_size = nil)
    tvm = VM.new
    ds = dev_size(dev)
    ds = [ds, max_size].min unless max_size.nil?
    tvm.add_allocation_volume(dev, 0, ds)

    md_size = tvm.free_space / 16
    tvm.add_volume(VolumeDescription.new('md', md_size))
    block_size = 128
    data_size = tvm.free_space
    tvm.add_volume(VolumeDescription.new('data', data_size))

    with_devs(tvm.table('md'),
              tvm.table('data')) do |md, data|

      # zero the metadata so we get a fresh pool
      wipe_device(md, 8)

      with_devs(Table.new(ThinPool.new(data_size, md, data, 128, 0))) do |pool|
        with_new_thin(pool, data_size, 0) do |thin|
          yield(thin)
        end
      end
    end
  end

  def test_stacked_pools
    with_pool_volume(@data_dev, @volume_size) do |layer1|
      with_pool_volume(layer1) do |layer2|
        with_pool_volume(layer2) do |layer3|
          dt_device(layer3)
        end
      end
    end
  end
end