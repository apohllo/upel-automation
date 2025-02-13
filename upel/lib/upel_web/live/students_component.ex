defmodule UpelWeb.StudentsComponent do
  use UpelWeb, :live_component

  @impl true
  def mount(socket) do
    socket = socket
    |> assign(:url, "https://upel.agh.edu.pl/")
    |> allow_upload(:cookie_file, accept: [".txt"], max_entries: 1)
    {:ok, socket}
  end

  @impl true
  def handle_event("validate", %{"_target" => ["cookie_file"]}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("validate", %{"_target" => ["url"]}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("fetch_students", %{"url" => url}, socket) do
    IO.inspect(url)
    entries = consume_uploaded_entries(socket, :cookie_file, fn %{path: path}, _entry ->
      {:ok, content} = File.read(path)
      File.write!("cookies.txt", content)
      {:ok, content}
    end)

    case entries do
      [content] ->
        cookies = parse_cookie_file(content)
        socket.assigns.on_fetch.(cookies, fetch_html(url, cookies))
      _ ->
        socket.assigns.on_fetch.(nil, {:error, "Error: No cookie file uploaded"})
    end
    {:noreply, socket}
  end

  def fetch_html(url, cookies) do
    case HTTPoison.get(url, [{"Cookie", cookies}]) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        {:ok, body}
      {:ok, %HTTPoison.Response{status_code: status_code, body: body}} ->
        {:error, "Error: Received status code #{status_code} #{body}"}
      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, "Error: #{inspect(reason)}"}
    end
  end

  defp parse_cookie_file(content) do
    content
    |> String.split("\n")
    |> Enum.filter(&(String.starts_with?(&1, "#") == false))
    |> Enum.filter(&(&1 != ""))
    |> Enum.map(fn line ->
      [_domain, _include_subdomains, _path, _secure, _expiry, name, value] = String.split(line, "\t")
      {name, value}
    end)
    |> Enum.map(fn {name, value} -> "#{name}=#{value}" end)
    |> Enum.join("; ")
  end

end
