defmodule OctoPi.Coder.Tools.BashTest do
  use ExUnit.Case, async: false

  alias OctoPi.Agent.AbortRef
  alias OctoPi.Agent.Tool.Result
  alias OctoPi.AI.Content
  alias OctoPi.Coder.Tools.Bash

  setup do
    ref = AbortRef.new()
    on_exit(fn -> AbortRef.forget(ref) end)
    {:ok, ref: ref}
  end

  describe "basic execution" do
    test "captures stdout from a simple command", %{ref: ref} do
      assert {:ok, %Result{content: [%Content.Text{text: text}], is_error?: false}} =
               Bash.execute("id", %{"_cwd" => File.cwd!(), "cmd" => "echo hi"}, ref, fn _ ->
                 :ok
               end)

      assert text =~ "hi"
    end

    test "captures stderr too", %{ref: ref} do
      assert {:ok, %Result{content: [%Content.Text{text: text}]}} =
               Bash.execute(
                 "id",
                 %{"_cwd" => File.cwd!(), "cmd" => "echo errmsg 1>&2"},
                 ref,
                 fn _ -> :ok end
               )

      assert text =~ "errmsg"
    end

    test "non-zero exit sets is_error?", %{ref: ref} do
      assert {:ok, %Result{is_error?: true, details: %{exit_status: status}}} =
               Bash.execute("id", %{"_cwd" => File.cwd!(), "cmd" => "exit 7"}, ref, fn _ ->
                 :ok
               end)

      assert status == 7
    end
  end

  describe "streaming updates" do
    test "on_update fires for streaming output", %{ref: ref} do
      test_pid = self()
      on_update = fn partial -> send(test_pid, {:update, partial}) end

      cmd = "for i in 1 2 3; do echo line$i; sleep 0.05; done"

      assert {:ok, %Result{}} =
               Bash.execute("id", %{"_cwd" => File.cwd!(), "cmd" => cmd}, ref, on_update)

      # At least two partial updates (streaming, not just one big
      # flush at the end).
      updates =
        fn ->
          receive do
            {:update, _} = m -> m
          after
            0 -> :done
          end
        end
        |> Stream.repeatedly()
        |> Enum.take_while(&(&1 != :done))

      assert length(updates) >= 2
    end
  end

  describe "timeout" do
    test "commands that exceed timeout_ms are killed", %{ref: ref} do
      {elapsed_us, {:ok, result}} =
        :timer.tc(fn ->
          Bash.execute(
            "id",
            %{"_cwd" => File.cwd!(), "cmd" => "sleep 10", "timeout_ms" => 200},
            ref,
            fn _ -> :ok end
          )
        end)

      assert %Result{is_error?: true, details: %{reason: :timeout}} = result
      # Should be under 1s (was 10s sleep).
      assert elapsed_us < 1_500_000
    end
  end

  describe "cwd enforcement" do
    test "rejects a cwd arg that escapes the session cwd", %{ref: ref} do
      tmp = Path.join(System.tmp_dir!(), "bash-cwd-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      assert {:ok, %Result{is_error?: true, content: [%Content.Text{text: msg}]}} =
               Bash.execute(
                 "id",
                 %{"_cwd" => tmp, "cmd" => "echo hi", "cwd" => "/etc"},
                 ref,
                 fn _ -> :ok end
               )

      assert msg =~ "escapes session cwd"
    end
  end

  describe "abort" do
    test "aborted_ref flips mid-run kills the command", %{ref: ref} do
      test_pid = self()

      task =
        Task.async(fn ->
          Bash.execute("id", %{"_cwd" => File.cwd!(), "cmd" => "sleep 30"}, ref, fn p ->
            send(test_pid, {:started, p})
          end)
        end)

      AbortRef.abort(ref)

      {elapsed_us, {:ok, result}} =
        :timer.tc(fn -> Task.await(task, 5_000) end)

      assert %Result{is_error?: true, details: %{reason: :aborted}} = result
      assert elapsed_us < 2_000_000
    end
  end
end
