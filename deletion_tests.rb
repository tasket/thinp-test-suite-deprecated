require 'config'
require 'lib/dm'
require 'lib/log'
require 'lib/process'
require 'lib/status'
require 'lib/utils'
require 'lib/tags'
require 'lib/thinp-test'

#----------------------------------------------------------------

class DeletionTests < ThinpTestCase
  include Tags
  include Utils

  def setup
    super
  end

  tag :thinp_target

  def test_create_delete_cycle
    with_standard_pool(@size) do |pool|
      1000.times do
        pool.message(0, "create_thin 0")
        pool.message(0, "delete 0")
      end
    end
  end

  def test_create_many_thins_then_delete_them
    with_standard_pool(@size) do |pool|
      0.upto(999) do |i|
        pool.message(0, "create_thin #{i}")
      end

      0.upto(999) do |i|
        pool.message(0, "delete #{i}")
      end
    end
  end

  def test_rolling_create_delete
    with_standard_pool(@size) do |pool|
      0.upto(999) do |i|
        pool.message(0, "create_thin #{i}")
      end

      0.upto(999) do |i|
        pool.message(0, "delete #{i}")
        pool.message(0, "create_thin #{i}")
      end
    end
  end

  def test_delete_thin
    with_standard_pool(@size) do |pool|
      with_new_thin(pool, @tiny_size, 0) do |thin|
        wipe_device(thin)
      end

      status = PoolStatus.new(pool)
      assert_equal(@size - @tiny_size, status.free_data_sectors)

      pool.message(0, 'delete 0')
      status = PoolStatus.new(pool)
      assert_equal(@size, status.free_data_sectors)
    end
  end

  tag :thinp_target, :quick

  def test_delete_unknown_devices
    with_standard_pool(@size) do |pool|
      0.upto(10) do |i|
        assert_raises(RuntimeError) do
          pool.message(0, "delete #{i}")
        end
      end
    end
  end

  def test_delete_active_device_fails
    with_standard_pool(@size) do |pool|
      with_new_thin(pool, @size, 0) do |thin|
        assert_raises(RuntimeError) do
          pool.message(0, 'delete 0')
        end
      end
    end
  end
end

#----------------------------------------------------------------
