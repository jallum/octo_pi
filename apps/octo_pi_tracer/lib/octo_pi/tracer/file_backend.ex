defmodule OctoPi.Tracer.FileBackend do
  @handler_id :octo_pi_tracer_file

  def install(path) do
    OctoPi.Tracer.attach_all()

    :logger.add_handler(@handler_id, __MODULE__, %{
      level: :debug,
      config: %{path: path},
      filter_default: :stop,
      filters: [
        {:tracer_domain, {&__MODULE__.filter_domain/2, nil}}
      ]
    })
  end

  def uninstall do
    :logger.remove_handler(@handler_id)
  end

  def filter_domain(%{meta: %{domain: domain}} = event, _extra) when is_list(domain) do
    if :octo_pi_tracer in domain, do: event, else: :stop
  end

  def filter_domain(_event, _extra), do: :stop

  def adding_handler(%{config: %{path: path}} = config) do
    case File.open(path, [:write]) do
      {:ok, io} ->
        File.close(io)
        {:ok, config}

      {:error, _} = error ->
        error
    end
  end

  def removing_handler(_config), do: :ok

  def log(%{msg: {:string, msg}}, %{config: %{path: path}}) do
    File.write!(path, [msg, "\n"], [:append])
  end

  def log(_event, _config), do: :ok
end
