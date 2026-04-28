defmodule OctoPi.TracerTest do
  use ExUnit.Case, async: false

  setup do
    # The ETS table is created once at application start; ensure it's clean per test
    :ets.delete_all_objects(OctoPi.Tracer)
    :ok
  end

  describe "register/1 and registered/0" do
    test "registered/0 returns empty list when nothing registered" do
      assert OctoPi.Tracer.registered() == []
    end

    test "register/1 stores a spec and registered/0 returns it" do
      spec = %{
        id: :my_handler,
        description: "handles my events",
        events: [[:my_app, :thing, :start]],
        level: :info
      }

      assert :ok = OctoPi.Tracer.register(spec)
      assert [^spec] = OctoPi.Tracer.registered()
    end

    test "register/1 overwrites an existing spec with the same id" do
      spec1 = %{id: :dup, description: "first", events: [], level: :info}
      spec2 = %{id: :dup, description: "second", events: [], level: :debug}

      OctoPi.Tracer.register(spec1)
      OctoPi.Tracer.register(spec2)

      assert [^spec2] = OctoPi.Tracer.registered()
    end

    test "registered/0 returns specs sorted by id" do
      OctoPi.Tracer.register(%{id: :z_handler, description: "", events: [], level: :info})
      OctoPi.Tracer.register(%{id: :a_handler, description: "", events: [], level: :info})
      OctoPi.Tracer.register(%{id: :m_handler, description: "", events: [], level: :info})

      ids = OctoPi.Tracer.registered() |> Enum.map(& &1.id)
      assert ids == [:a_handler, :m_handler, :z_handler]
    end
  end
end
