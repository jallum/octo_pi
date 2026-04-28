defmodule OctoPi.Coder.SettingsManagerTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.SettingsManager
  alias OctoPi.Coder.Compaction.Settings, as: CompactionSettings

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    global_dir = Path.join(tmp_dir, "agent")
    project_dir = Path.join(tmp_dir, "project")
    pi_dir = Path.join(project_dir, ".pi")
    File.mkdir_p!(global_dir)
    File.mkdir_p!(pi_dir)
    {:ok, global_dir: global_dir, project_dir: project_dir, pi_dir: pi_dir}
  end

  # ── load/2 — missing files ────────────────────────────────────────────────

  describe "load/2 — missing files" do
    test "both files missing → empty merged, no errors", %{project_dir: project_dir, global_dir: global_dir} do
      sm = SettingsManager.load(project_dir, global_dir: global_dir)
      assert sm.merged == %{}
      assert sm.errors == []
    end

    test "missing global file is silently ignored", %{project_dir: project_dir, global_dir: global_dir, pi_dir: pi_dir} do
      File.write!(Path.join(pi_dir, "settings.json"), ~s|{"foo": "bar"}|)
      sm = SettingsManager.load(project_dir, global_dir: global_dir)
      assert sm.merged == %{"foo" => "bar"}
      assert sm.errors == []
    end

    test "missing project file is silently ignored", %{project_dir: project_dir, global_dir: global_dir} do
      File.write!(Path.join(global_dir, "settings.json"), ~s|{"foo": "global"}|)
      sm = SettingsManager.load(project_dir, global_dir: global_dir)
      assert sm.merged == %{"foo" => "global"}
      assert sm.errors == []
    end
  end

  # ── load/2 — merge precedence ─────────────────────────────────────────────

  describe "load/2 — merge precedence" do
    test "project scalar overrides global scalar", %{project_dir: project_dir, global_dir: global_dir, pi_dir: pi_dir} do
      File.write!(Path.join(global_dir, "settings.json"), ~s|{"theme": "dark", "foo": "global"}|)
      File.write!(Path.join(pi_dir, "settings.json"), ~s|{"theme": "light"}|)
      sm = SettingsManager.load(project_dir, global_dir: global_dir)
      assert sm.merged["theme"] == "light"
      assert sm.merged["foo"] == "global"
    end

    test "project array replaces global array wholesale", %{project_dir: project_dir, global_dir: global_dir, pi_dir: pi_dir} do
      File.write!(Path.join(global_dir, "settings.json"), ~s|{"extensions": ["/a.ts", "/b.ts"]}|)
      File.write!(Path.join(pi_dir, "settings.json"), ~s|{"extensions": ["/c.ts"]}|)
      sm = SettingsManager.load(project_dir, global_dir: global_dir)
      assert sm.merged["extensions"] == ["/c.ts"]
    end

    test "project nested map merges with global nested map", %{project_dir: project_dir, global_dir: global_dir, pi_dir: pi_dir} do
      File.write!(Path.join(global_dir, "settings.json"), ~s|{"compaction": {"enabled": false, "reserveTokens": 8192}}|)
      File.write!(Path.join(pi_dir, "settings.json"), ~s|{"compaction": {"enabled": true}}|)
      sm = SettingsManager.load(project_dir, global_dir: global_dir)
      comp = sm.merged["compaction"]
      assert comp["enabled"] == true
      assert comp["reserveTokens"] == 8192
    end

    test "global_settings and project_settings preserved separately", %{project_dir: project_dir, global_dir: global_dir, pi_dir: pi_dir} do
      File.write!(Path.join(global_dir, "settings.json"), ~s|{"x": 1}|)
      File.write!(Path.join(pi_dir, "settings.json"), ~s|{"y": 2}|)
      sm = SettingsManager.load(project_dir, global_dir: global_dir)
      assert sm.global_settings == %{"x" => 1}
      assert sm.project_settings == %{"y" => 2}
      assert sm.merged == %{"x" => 1, "y" => 2}
    end
  end

  # ── load/2 — error collection ─────────────────────────────────────────────

  describe "load/2 — error collection" do
    test "invalid global JSON collected as :global error", %{project_dir: project_dir, global_dir: global_dir} do
      File.write!(Path.join(global_dir, "settings.json"), "{ invalid")
      sm = SettingsManager.load(project_dir, global_dir: global_dir)
      assert length(sm.errors) == 1
      assert hd(sm.errors).scope == :global
      assert hd(sm.errors).reason =~ "JSON parse error"
      assert sm.global_settings == %{}
    end

    test "invalid project JSON collected as :project error", %{project_dir: project_dir, global_dir: global_dir, pi_dir: pi_dir} do
      File.write!(Path.join(pi_dir, "settings.json"), "{ invalid")
      sm = SettingsManager.load(project_dir, global_dir: global_dir)
      assert length(sm.errors) == 1
      assert hd(sm.errors).scope == :project
      assert sm.project_settings == %{}
    end

    test "both files invalid → two errors collected", %{project_dir: project_dir, global_dir: global_dir, pi_dir: pi_dir} do
      File.write!(Path.join(global_dir, "settings.json"), "{ bad global")
      File.write!(Path.join(pi_dir, "settings.json"), "{ bad project")
      sm = SettingsManager.load(project_dir, global_dir: global_dir)
      assert length(sm.errors) == 2
      assert Enum.map(sm.errors, & &1.scope) |> Enum.sort() == [:global, :project]
    end

    test "non-object JSON (array) collected as error", %{project_dir: project_dir, global_dir: global_dir} do
      File.write!(Path.join(global_dir, "settings.json"), "[1,2,3]")
      sm = SettingsManager.load(project_dir, global_dir: global_dir)
      assert length(sm.errors) == 1
      assert hd(sm.errors).reason =~ "not a JSON object"
    end
  end

  # ── deep_merge/2 ──────────────────────────────────────────────────────────

  describe "deep_merge/2" do
    test "override scalar wins" do
      assert SettingsManager.deep_merge(%{"a" => 1}, %{"a" => 2}) == %{"a" => 2}
    end

    test "base keys absent from override are preserved" do
      assert SettingsManager.deep_merge(%{"a" => 1, "b" => 2}, %{"b" => 3}) == %{"a" => 1, "b" => 3}
    end

    test "new keys in override are added" do
      assert SettingsManager.deep_merge(%{"a" => 1}, %{"b" => 2}) == %{"a" => 1, "b" => 2}
    end

    test "nested map is shallow-merged one level deep" do
      base = %{"opts" => %{"x" => 1, "y" => 2}}
      over = %{"opts" => %{"x" => 99}}
      result = SettingsManager.deep_merge(base, over)
      assert result["opts"] == %{"x" => 99, "y" => 2}
    end

    test "override array replaces base array wholesale" do
      base = %{"tags" => ["a", "b"]}
      over = %{"tags" => ["c"]}
      assert SettingsManager.deep_merge(base, over)["tags"] == ["c"]
    end

    test "empty override returns base" do
      base = %{"a" => 1}
      assert SettingsManager.deep_merge(base, %{}) == base
    end

    test "empty base returns override" do
      over = %{"a" => 1}
      assert SettingsManager.deep_merge(%{}, over) == over
    end
  end

  # ── get_compaction_settings/1 ─────────────────────────────────────────────

  describe "get_compaction_settings/1" do
    test "returns struct defaults when compaction key absent" do
      sm = SettingsManager.in_memory(%{})
      s = SettingsManager.get_compaction_settings(sm)
      assert %CompactionSettings{enabled: true, reserve_tokens: 16_384, keep_recent_tokens: 20_000} = s
    end

    test "reads enabled=false from merged map" do
      sm = SettingsManager.in_memory(%{"compaction" => %{"enabled" => false}})
      s = SettingsManager.get_compaction_settings(sm)
      assert s.enabled == false
      assert s.reserve_tokens == 16_384
    end

    test "reads reserveTokens (camelCase JSON key)" do
      sm = SettingsManager.in_memory(%{"compaction" => %{"reserveTokens" => 8_192}})
      s = SettingsManager.get_compaction_settings(sm)
      assert s.reserve_tokens == 8_192
    end

    test "reads keepRecentTokens (camelCase JSON key)" do
      sm = SettingsManager.in_memory(%{"compaction" => %{"keepRecentTokens" => 10_000}})
      s = SettingsManager.get_compaction_settings(sm)
      assert s.keep_recent_tokens == 10_000
    end

    test "non-integer value for token count falls back to default" do
      sm = SettingsManager.in_memory(%{"compaction" => %{"reserveTokens" => "big"}})
      s = SettingsManager.get_compaction_settings(sm)
      assert s.reserve_tokens == 16_384
    end

    test "non-boolean for enabled falls back to default" do
      sm = SettingsManager.in_memory(%{"compaction" => %{"enabled" => "yes"}})
      s = SettingsManager.get_compaction_settings(sm)
      assert s.enabled == true
    end

    test "project compaction overrides global via load/2", %{project_dir: project_dir, global_dir: global_dir, pi_dir: pi_dir} do
      File.write!(Path.join(global_dir, "settings.json"), ~s|{"compaction": {"enabled": false, "reserveTokens": 4096}}|)
      File.write!(Path.join(pi_dir, "settings.json"), ~s|{"compaction": {"reserveTokens": 32768}}|)
      sm = SettingsManager.load(project_dir, global_dir: global_dir)
      s = SettingsManager.get_compaction_settings(sm)
      assert s.enabled == false
      assert s.reserve_tokens == 32_768
    end
  end

  # ── in_memory/1 ───────────────────────────────────────────────────────────

  describe "in_memory/1" do
    test "wraps map as merged with no errors" do
      settings = %{"theme" => "dark"}
      sm = SettingsManager.in_memory(settings)
      assert sm.merged == settings
      assert sm.errors == []
    end

    test "defaults to empty map" do
      sm = SettingsManager.in_memory()
      assert sm.merged == %{}
    end
  end
end
