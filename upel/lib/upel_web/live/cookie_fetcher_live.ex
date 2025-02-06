defmodule UpelWeb.CookieFetcherLive do
  use UpelWeb, :live_view
  require Logger
  require Floki

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:uploaded_cookies, nil)
     |> assign(:url, "https://upel.agh.edu.pl/mod/quiz/report.php?id=193798&mode=overview&attempts=enrolled_with&onlygraded=&group=9163&onlyregraded=&slotmarks=1&group=9164")
     |> assign(:html_content, nil)
     |> assign(:extracted_data, nil)
     |> assign(:qas, [])
     |> assign(:position, nil)
     |> assign(:question_id, nil)
     |> assign(:sequence_ids, [])
     |> assign(:attempt, nil)
     |> assign(:session_id, nil)
     |> allow_upload(:cookie_file, accept: [".txt"], max_entries: 1)}
  end

  def handle_event("validate", %{"_target" => ["cookie_file"]}, socket) do
    {:noreply, socket}
  end

  def handle_event("validate", %{"_target" => ["url"]}, socket) do
    {:noreply, socket}
  end

  def handle_event("upload_cookies", %{"url" => url}, socket) do
    entries = consume_uploaded_entries(socket, :cookie_file, fn %{path: path}, _entry ->
      {:ok, content} = File.read(path)
      {:ok, content}
    end)

    case entries do
      [content] ->
        cookies = parse_cookie_file(content)
        IO.inspect(cookies)
        case fetch_html(url, cookies, socket) do
          {:ok, body} ->
            extracted_data = extract_student_data(body)
            {:noreply,
              socket
              |> assign(:uploaded_cookies, cookies)
              |> assign(:url, url)
              |> assign(:extracted_data, extracted_data)}
          {:error, response} ->
            response
        end
      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("fetch_answers", %{"url" => url, "position" => position}, socket) do
    attempt = List.last(Regex.run(~r'attempt=([^&]+)', url))
    IO.inspect(attempt, label: "Extracted Attempt")

    cookies = socket.assigns.uploaded_cookies
    case fetch_html(url, cookies, socket) do
      {:ok, body} ->
        position = String.to_integer(position)
        session_id = parse_session_id(body)
        answers = parse_answers(body)
        question_ids = answers
        |> Enum.map(fn answer ->
          {question_code, sequence_id} = answer.sequence
          [question_id, slot_id, _] = String.split(question_code, ":")
          {question_id, slot_id, sequence_id}
        end)
        question_id = elem(List.first(question_ids), 0)
        sequence_ids = question_ids
        |> Enum.map(fn {_, _, sequence_id} -> sequence_id end)

        IO.inspect(answers)
        IO.inspect(position)

        {:noreply,
          socket
          |> assign(:qas, answers)
          |> assign(:question_id, question_id)
          |> assign(:sequence_ids, sequence_ids)
          |> assign(:position, position)
          |> assign(:attempt, attempt)
          |> assign(:session_id, session_id)}
      {:error, response} ->
        response
    end
  end

  def handle_event("add_feedback", params, socket) do
    IO.inspect(params)

    feedbacks = Enum.map(1..3, fn index ->
      comment = Enum.at(params["comment"], index - 1)
      mark = Enum.at(params["mark"], index - 1)
      sequence_id = Enum.at(params["sequence_ids"], index - 1)

      {comment, mark, sequence_id}
    end)
    IO.inspect(feedbacks)

    feedbacks
    |> Enum.with_index()
    |> Enum.each(fn {{comment, mark, sequence_id}, index} ->
      post_params = build_post_params(socket.assigns.attempt,
        socket.assigns.question_id,
        1 + index,
        sequence_id,
        mark,
        comment,
        socket.assigns.session_id)
      case HTTPoison.get("https://upel.agh.edu.pl/mod/quiz/comment.php?attempt=#{socket.assigns.attempt}&slot=#{index + 1}",
          [{"Cookie", socket.assigns.uploaded_cookies}]) do
        {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
          IO.inspect("success")
          {:ok, body} = Floki.parse_document(body)
          http_params = body
          |> Floki.find("form")
          |> List.first()
          |> Floki.find("input")
          |> Enum.map(fn el -> 
            elem(el, 1) 
            |> Keyword.take(["name", "value"]) 
            |> Enum.map(fn el1 -> 
              elem(el1, 1) 
            end) 
          end)
          |> List.foldl(%{}, fn el1, acc ->
            Map.put(acc, List.first(el1), List.last(el1))
          end) 
          http_params |> IO.inspect()
          mark_key = Map.keys(http_params) |> Enum.find(fn el -> Regex.run(~r"-mark$", el) end)
          mark_key |> IO.inspect()
          comment_key = String.replace(mark_key, "-mark", "-comment")
          http_params = http_params
            |> Map.put(mark_key, mark)
            |> Map.put(comment_key, comment)
            |> URI.encode_query()

          case HTTPoison.post("https://upel.agh.edu.pl/mod/quiz/comment.php",
            http_params, [{"Cookie", socket.assigns.uploaded_cookies},{"Content-Type", "application/x-www-form-urlencoded"}]) do
            {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
              IO.inspect("success")
              {:ok, body} = Floki.parse_document(body)
              body = body
              |> Floki.find("body")
              |> Floki.text()
              IO.inspect(body)
              body = body
              |> Floki.find("input")
              IO.inspect(body)
            {:ok, %HTTPoison.Response{status_code: 404, body: body}} ->
              IO.inspect("error 404")
            {:ok, %HTTPoison.Response{status_code: 303, body: body}} ->
              IO.inspect("error")
              {:ok, body} = Floki.parse_document(body)
              body = body
              |> Floki.find("body")
              |> Floki.text()
              IO.inspect(body)
            {:error, response} ->
              IO.inspect("error")
              IO.inspect(response)
          end
        _ ->
          IO.inspect("error")
      end
    end)
    {:noreply, socket}
  end

  defp parse_session_id(body) do
    case Floki.parse_document(body) do
      {:ok, document} ->
        href = document
        |> Floki.find("a[href*='logout']")
        |> List.first()
        |> Floki.attribute("href")
        |> List.first()

        Regex.run(~r/sesskey=([^&]+)/, href)
        |> case do
          [_, key] -> key
          _ -> nil
        end
      _ ->
        nil
    end
  end

  defp build_post_params(attempt, question_id, slot_id, sequence_id, mark, comment, session_id) do
    %{"attempt" => attempt,
      "slot" => slot_id,
      "slots" => slot_id,
      "#{question_id}:#{slot_id}_:sequencecheck" => sequence_id,
      "#{question_id}:#{slot_id}_-mark" => mark,
      "#{question_id}:#{slot_id}_-maxmark" => "1",
      "#{question_id}:#{slot_id}_:minfraction" => "0",
      "#{question_id}:#{slot_id}_:maxfraction" => "1",
      "#{question_id}:#{slot_id}_-comment" => comment,
      "#{question_id}:#{slot_id}_-commentformat" => "1",
      "submit" => "Zapisz",
      "sesskey" => session_id} |> URI.encode_query()
  end

  defp parse_answers(body) do
    case Floki.parse_document(body) do
      {:ok, document} ->
        document
        |> Floki.find("div[class*='formulation']")
        |> Enum.map(fn row ->
          question = row
          |> Floki.find("div[class*='qtext']")
          |> List.first()
          |> Floki.text()

          answer = row
          |> Floki.find("div[class*='qtype_essay_response']")
          |> List.first()
          |> Floki.text()

          hidden_input = row
          |> Floki.find("input[type='hidden']")
          |> Enum.map(fn input ->
            name = input |> Floki.attribute("name") |> List.first()
            value = input |> Floki.attribute("value") |> List.first()
            {name, value}
          end)
          |> List.first()

          %{question: question, answer: answer, sequence: hidden_input}
        end)
    end
  end

  defp fetch_html(url, cookies, socket) do
    case HTTPoison.get(url, [{"Cookie", cookies}]) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        {:ok, body}
      {:ok, %HTTPoison.Response{status_code: status_code, body: body}} ->
        {:error,
        {:noreply,
          socket
          |> assign(:html_content, "Error: Received status code #{status_code} #{body}")}}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error,
        {:noreply,
          socket
          |> assign(:html_content, "Error: #{inspect(reason)}")}}
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

  defp extract_student_data(html) do
    case Floki.parse_document(html) do
      {:ok, document} ->
        document
        |> Floki.find("td[class*='sticky-column']")
        |> Enum.map(fn row ->
          name = row
                 |> Floki.find("a")  # Find the anchor tag within the sticky column
                 |> List.first()
                 |> Floki.text()
                 |> String.trim()

          url = row
                |> Floki.find("a")
                |> List.last()
                |> case do
                     nil -> nil
                     link -> Floki.attribute(link, "href") |> List.first()
                   end

          tuple = %{name: name, url: url}
          tuple
        end)
        |> Enum.filter(fn %{name: name, url: url} -> name != nil and url != nil end)

      _ ->
        IO.inspect("error parsing html")
        []
    end
  end
end
