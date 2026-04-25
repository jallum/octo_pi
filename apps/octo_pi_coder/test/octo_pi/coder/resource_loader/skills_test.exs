defmodule OctoPi.Coder.ResourceLoader.SkillsTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.ResourceLoader.Skills

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "skills_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  defp write_skill(base_dir, skill_name, frontmatter_fields, body \\ "") do
    skill_dir = Path.join(base_dir, skill_name)
    File.mkdir_p!(skill_dir)
    fm = Enum.map_join(frontmatter_fields, "\n", fn {k, v} -> "#{k}: #{v}" end)
    content = "---\n#{fm}\n---\n#{body}"
    File.write!(Path.join(skill_dir, "SKILL.md"), content)
    skill_dir
  end

  describe "load_all/2" do
    test "returns empty list when no skills dirs exist" do
      cwd = tmp_dir()
      on_exit(fn -> File.rm_rf!(cwd) end)
      assert Skills.load_all(cwd, nil) == []
    end

    test "loads skill from project skills dir" do
      cwd = tmp_dir()
      project_skills = Path.join([cwd, ".pi", "skills"])
      write_skill(project_skills, "my-skill", [{"name", "my-skill"}, {"description", "Does something"}])
      on_exit(fn -> File.rm_rf!(cwd) end)

      skills = Skills.load_all(cwd, nil)
      assert length(skills) == 1
      assert List.first(skills).name == "my-skill"
      assert List.first(skills).description == "Does something"
    end

    test "loads skill from global skills dir" do
      global_dir = tmp_dir()
      cwd = tmp_dir()

      write_skill(Path.join(global_dir, "skills"), "global-skill", [
        {"name", "global-skill"},
        {"description", "Global skill"}
      ])

      on_exit(fn ->
        File.rm_rf!(global_dir)
        File.rm_rf!(cwd)
      end)

      skills = Skills.load_all(cwd, global_dir)
      assert Enum.any?(skills, &(&1.name == "global-skill"))
    end

    test "loads skills from both global and project dirs" do
      global_dir = tmp_dir()
      cwd = tmp_dir()

      write_skill(Path.join(global_dir, "skills"), "global-skill", [{"name", "global-skill"}, {"description", "Global"}])

      write_skill(Path.join([cwd, ".pi", "skills"]), "proj-skill", [{"name", "proj-skill"}, {"description", "Project"}])

      on_exit(fn ->
        File.rm_rf!(global_dir)
        File.rm_rf!(cwd)
      end)

      skills = Skills.load_all(cwd, global_dir)
      assert length(skills) == 2
      names = MapSet.new(skills, & &1.name)
      assert MapSet.member?(names, "global-skill")
      assert MapSet.member?(names, "proj-skill")
    end

    test "skill with missing description is not loaded" do
      cwd = tmp_dir()
      write_skill(Path.join([cwd, ".pi", "skills"]), "bad-skill", [{"name", "bad-skill"}])
      on_exit(fn -> File.rm_rf!(cwd) end)

      assert Skills.load_all(cwd, nil) == []
    end

    test "skill with empty description is not loaded" do
      cwd = tmp_dir()
      write_skill(Path.join([cwd, ".pi", "skills"]), "bad-skill", [{"name", "bad-skill"}, {"description", ""}])
      on_exit(fn -> File.rm_rf!(cwd) end)

      assert Skills.load_all(cwd, nil) == []
    end

    test "disable_model_invocation defaults to false" do
      cwd = tmp_dir()
      write_skill(Path.join([cwd, ".pi", "skills"]), "my-skill", [{"name", "my-skill"}, {"description", "Desc"}])
      on_exit(fn -> File.rm_rf!(cwd) end)

      [skill] = Skills.load_all(cwd, nil)
      assert skill.disable_model_invocation == false
    end

    test "disable-model-invocation: true is respected" do
      cwd = tmp_dir()

      write_skill(Path.join([cwd, ".pi", "skills"]), "hidden-skill", [
        {"name", "hidden-skill"},
        {"description", "Hidden"},
        {"disable-model-invocation", "true"}
      ])

      on_exit(fn -> File.rm_rf!(cwd) end)

      [skill] = Skills.load_all(cwd, nil)
      assert skill.disable_model_invocation == true
    end

    test "name defaults to parent directory name when omitted from frontmatter" do
      cwd = tmp_dir()
      skill_dir = Path.join([cwd, ".pi", "skills", "auto-named"])
      File.mkdir_p!(skill_dir)
      File.write!(Path.join(skill_dir, "SKILL.md"), "---\ndescription: Auto named skill\n---\n")
      on_exit(fn -> File.rm_rf!(cwd) end)

      [skill] = Skills.load_all(cwd, nil)
      assert skill.name == "auto-named"
    end

    test "file_path points to SKILL.md" do
      cwd = tmp_dir()
      write_skill(Path.join([cwd, ".pi", "skills"]), "my-skill", [{"name", "my-skill"}, {"description", "Desc"}])
      on_exit(fn -> File.rm_rf!(cwd) end)

      [skill] = Skills.load_all(cwd, nil)
      assert String.ends_with?(skill.file_path, "SKILL.md")
    end

    test "deduplicates skills with same name — first loaded wins" do
      global_dir = tmp_dir()
      cwd = tmp_dir()

      write_skill(Path.join(global_dir, "skills"), "dup-skill", [
        {"name", "dup-skill"},
        {"description", "Global version"}
      ])

      write_skill(Path.join([cwd, ".pi", "skills"]), "dup-skill", [
        {"name", "dup-skill"},
        {"description", "Project version"}
      ])

      on_exit(fn ->
        File.rm_rf!(global_dir)
        File.rm_rf!(cwd)
      end)

      skills = Skills.load_all(cwd, global_dir)
      assert length(skills) == 1
    end

    test "skill SKILL.md is not recursed into further" do
      cwd = tmp_dir()
      skill_dir = Path.join([cwd, ".pi", "skills", "my-skill"])
      nested = Path.join([skill_dir, "nested"])
      File.mkdir_p!(nested)
      File.write!(Path.join(skill_dir, "SKILL.md"), "---\ndescription: Top skill\n---\n")
      File.write!(Path.join(nested, "SKILL.md"), "---\nname: nested\ndescription: Nested\n---\n")
      on_exit(fn -> File.rm_rf!(cwd) end)

      skills = Skills.load_all(cwd, nil)
      # Only the top-level skill is loaded, not the nested one
      assert length(skills) == 1
    end
  end
end
