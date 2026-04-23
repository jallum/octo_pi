defmodule OctoPi.Coder.FileMutexTest do
  use ExUnit.Case, async: false

  alias OctoPi.Coder.FileMutex

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "octo-pi-coder-mutex-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  describe "with_lock/2" do
    test "runs the function and returns its value", %{tmp: tmp} do
      path = Path.join(tmp, "a.txt")
      assert 42 = FileMutex.with_lock(path, fn -> 42 end)
    end

    test "two concurrent calls on the same path are serialized", %{tmp: tmp} do
      path = Path.join(tmp, "shared.txt")
      test_pid = self()

      first =
        Task.async(fn ->
          FileMutex.with_lock(path, fn ->
            send(test_pid, {:enter, :first})
            # Yield so task 2 has a chance to queue if it weren't
            # serialized — it will block on the GenServer.call
            # because handle_call is one-at-a-time.
            receive do
              :release -> :ok
            after
              200 -> :ok
            end

            send(test_pid, {:exit, :first})
            :first_done
          end)
        end)

      # Ensure task 1 has entered the lock before task 2 tries to
      # acquire. The :enter message is the sync point.
      assert_receive {:enter, :first}, 500

      second =
        Task.async(fn ->
          FileMutex.with_lock(path, fn ->
            send(test_pid, {:enter, :second})
            :second_done
          end)
        end)

      # Task 2 should NOT have entered yet — task 1 is still inside.
      refute_receive {:enter, :second}, 50

      # Release task 1, then task 2 should proceed.
      send(first.pid, :release)
      assert_receive {:exit, :first}, 500
      assert_receive {:enter, :second}, 500

      assert :first_done = Task.await(first)
      assert :second_done = Task.await(second)
    end

    test "different paths run concurrently", %{tmp: tmp} do
      path_a = Path.join(tmp, "a.txt")
      path_b = Path.join(tmp, "b.txt")
      test_pid = self()

      Task.async(fn ->
        FileMutex.with_lock(path_a, fn ->
          send(test_pid, {:enter, :a})

          receive do
            :release_a -> :ok
          after
            500 -> :ok
          end

          :done_a
        end)
      end)

      assert_receive {:enter, :a}, 500

      # b's lock is independent — should enter immediately even though
      # a is still holding its lock.
      Task.async(fn ->
        FileMutex.with_lock(path_b, fn ->
          send(test_pid, {:enter, :b})
          :done_b
        end)
      end)

      assert_receive {:enter, :b}, 100
    end

    test "an exception in fun is re-raised; the lock is released", %{tmp: tmp} do
      path = Path.join(tmp, "raises.txt")

      assert_raise RuntimeError, "boom", fn ->
        FileMutex.with_lock(path, fn -> raise "boom" end)
      end

      # Lock should be freely re-acquirable after the raise.
      assert :ok = FileMutex.with_lock(path, fn -> :ok end)
    end

    test "worker self-terminates after the idle timeout", %{tmp: tmp} do
      original = Application.get_env(:octo_pi_coder, :file_mutex_idle_timeout)
      Application.put_env(:octo_pi_coder, :file_mutex_idle_timeout, 20)
      on_exit(fn -> Application.put_env(:octo_pi_coder, :file_mutex_idle_timeout, original) end)

      path = Path.join(tmp, "idle.txt")
      :ok = FileMutex.with_lock(path, fn -> :ok end)

      [{pid, _}] = Registry.lookup(OctoPi.Coder.FileMutex.Registry, Path.expand(path))
      ref = Process.monitor(pid)

      # With 20ms idle timeout, the worker should exit :normal shortly.
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500
    end
  end
end
