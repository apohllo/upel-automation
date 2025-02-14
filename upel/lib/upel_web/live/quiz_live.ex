defmodule UpelWeb.QuizLive do
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
     |> stream(:qas, [])
     |> assign(:position, nil)
     |> assign(:error, false)
     |> assign(:done, false)
    }
  end

  @impl true
  def handle_info({:fetch_students, cookies, data}, socket) do
    case data do
      {:ok, html} ->
        extracted_data = extract_student_data(html)
        {:noreply, socket
        |> assign(:uploaded_cookies, cookies)
        |> assign(:extracted_data, extracted_data)}
      {:error, error} ->
        {:noreply, socket |> assign(:error, error)}
    end
  end

  @impl true
  def handle_event("fetch_answers", %{"url" => url, "position" => position}, socket) do
    attempt = List.last(Regex.run(~r'attempt=([^&]+)', url))


    case fetch_html(url, socket.assigns.uploaded_cookies, socket) do
      {:ok, body} ->
        position = String.to_integer(position)
        send_update(UpelWeb.AnswersComponent, id: position, evaluate: true)
        pid = self()
        Task.start(fn ->
          parse_answers(body)
          |> Enum.with_index()
          |> List.foldl([], fn {answer, index}, answers ->
            answer = answer
              |> Map.put(:generated_mark, "not generated")
              |> Map.put(:generated_comment, "not generated")
              case read_attempt_params(attempt, index, socket.assigns.uploaded_cookies) do
                {:ok, params} ->
                  mark_key = Map.keys(params) |> Enum.find(fn el -> Regex.run(~r"-mark$", el) end)
                  comment_key = String.replace(mark_key, "-mark", "-comment")
                  answer = answer
                  |> Map.put(:params, params |> URI.encode_query())
                  |> Map.put(:mark, params[mark_key])
                  |> Map.put(:comment, params[comment_key])
                  |> Map.put(:index, index)
                  case grade_answer(answer.question, answer.answer) do
                    {:ok, grade} ->
                      answer = answer
                      |> Map.put(:generated_mark, grade.grade)
                      |> Map.put(:generated_comment, grade.comment)
                      answers = answers ++ [answer]
                      send_update(pid, UpelWeb.AnswersComponent, id: position, qas: answers)
                      answers
                    _ ->
                      IO.inspect("error in grading answer")
                      send_update(pid, UpelWeb.AnswersComponent, id: position, qas: answers)
                      answers
                  end
                _ ->
                  IO.inspect("error in reading attempt params")
                  answers = answers ++ [answer]
                  send_update(pid, UpelWeb.AnswersComponent, id: position, qas: answers)
                  answers
              end
            end)
        end)

        {:noreply,
          socket
          #|> assign(:qas, answers)
          |> assign(:position, position)
          |> assign(:done, false)
          |> assign(:attempt, attempt)}
      {:error, response} ->
        IO.inspect(response)
        {:noreply, socket |> assign(:error, true)}
    end
  end

  def handle_event("add_feedback", params, socket) do

    feedbacks = Enum.map(1..3, fn index ->
      comment = Enum.at(params["comment"], index - 1)
      mark = Enum.at(params["mark"], index - 1)
      http_params = Enum.at(params["params"], index - 1)
      {comment, mark, http_params}
    end)
    IO.inspect(feedbacks)

    error = feedbacks
    |> List.foldl(false, fn {comment, mark, http_params}, error ->
      http_params = http_params
      |> URI.decode_query()

      mark_key = Map.keys(http_params) |> Enum.find(fn el -> Regex.run(~r"-mark$", el) end)
      comment_key = String.replace(mark_key, "-mark", "-comment")
      http_params = http_params
        |> Map.put(mark_key, mark)
        |> Map.put(comment_key, comment)
        |> URI.encode_query()

      case HTTPoison.post("https://upel.agh.edu.pl/mod/quiz/comment.php",
        http_params, [{"Cookie", socket.assigns.uploaded_cookies},{"Content-Type", "application/x-www-form-urlencoded"}]) do
        {:ok, %HTTPoison.Response{status_code: 200, body: _body}} ->
          error
        {:ok, %HTTPoison.Response{status_code: 404, body: _body}} ->
          IO.inspect("error 404")
          true
        {:ok, %HTTPoison.Response{status_code: 303, body: _body}} ->
          IO.inspect("error 303")
          true
        {:error, response} ->
          IO.inspect("error")
          IO.inspect(response)
          true
      end
    end)
    if error do
      {:noreply, socket |> assign(:error, true)}
    else
      {:noreply, socket |> assign(:error, false) |> assign(:done, true)}
    end
  end

  defp grade_answer(question, answer) do
    model = System.get_env("API_MODEL") || "gpt-3.5-turbo"
    api_key = System.get_env("API_KEY")
    api_url = System.get_env("API_URL") || "https://api.openai.com/v1/chat/completions"

    IO.inspect(model)

    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ]

    body = Jason.encode!(%{
      "model" => model,
      "messages" => [
        %{
          "role" => "system",
          "content" =>
            "Jesteś ekspertem w zakresie oceniania odpowiedzi uczniów.\n" <>
            "Twoim zadaniem jest ocena jakości i poprawności odpowiedzi ucznia w skali od 0 do 1.\n" <>
            "Komentarz powinien być zwięzły, nie używaj form drugoosobowych.\n" <>
            "Zamiast 'Powinieneś bardziej dokładnie zdefiniować to pojęcie' użyj 'Pojęcie powinno być zdefiniowane dokładniej'.\n" <>
            "Zamiast 'Dodaj informację o drugim problemie' użyj 'Odpowiedź powinna zawierać również informacje o drugim problemie'.\n" <>
            "Zwróć ocenę jako 'grade' a komentarz jako 'comment' w formacie JSON.\n" <>
            "Nie dodawaj żadnego formatowania (np. ```json itp.), poza treścią dokumentu JSON.\n" <>
            "Zwróć tylko JSON, nic więcej."
        },
        %{
          "role" => "user",
          "content" => "Pytanie: #{question}\nOdpowiedź ucznia: #{answer}\nOceń jakość i poprawność tej odpowiedzi w skali od 0 do 1."
        }
      ],
      "temperature" => 0
    })

    case HTTPoison.post(api_url, body, headers) do
      {:ok, %HTTPoison.Response{status_code: 200, body: response_body}} ->
        case Jason.decode(response_body) do
          {:ok, decoded} ->
            case Jason.decode(Map.get(decoded, "choices") |> List.first() |> Map.get("message") |> Map.get("content")) do
              {:ok, inner_decoded} ->
                {:ok, Map.new(inner_decoded, fn {k, v} -> {String.to_atom(k), v} end)}
              {:error, error} ->
                IO.inspect("error in decoding inner JSON")
                {:ok, %{grade: "", comment: "Nie udało się ocenić odpowiedzi. Spróbuj ponownie."}}
            end
          _ ->
            IO.inspect("error in decoding outer JSON")
            {:ok, %{grade: "", comment: "Nie udało się ocenić odpowiedzi. Spróbuj ponownie."}}
        end
      {status, response} ->
        IO.inspect("error in getting response from API")
        IO.inspect(status)
        IO.inspect(response)
        {:ok, %{grade: "", comment: "Nie udało się ocenić odpowiedzi. Spróbuj ponownie."}}
    end
  end


  defp read_attempt_params(attempt, index, cookies) do
    case HTTPoison.get("https://upel.agh.edu.pl/mod/quiz/comment.php?attempt=#{attempt}&slot=#{index + 1}",
        [{"Cookie", cookies}]) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        IO.inspect("success")
        {:ok, body} = Floki.parse_document(body)
        html_form = body
        |> Floki.find("form")
        |> List.first()

        {:ok, extract_params(html_form, "input")
        |> Map.merge(html_form
          |> Floki.find("textarea")
          |> Enum.map(fn el ->
            name = el |> Floki.attribute("name") |> List.first()
            value = el |> Floki.text()
            {name, value}
          end)
          |> Enum.into(%{}))}
      _ ->
        IO.inspect("error")
        {:error, "error"}
    end
  end

  defp extract_params(html_doc, tag) do
    html_doc
    |> Floki.find(tag)
    |> Enum.map(fn {_tag, attrs, _children} ->
      Keyword.take(attrs, ["name", "value"])
      |> Enum.map(fn {_key, value} -> value end)
    end)
    |> List.foldl(%{}, fn el1, acc ->
      Map.put(acc, List.first(el1), List.last(el1))
    end)
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

  defp extract_student_data(html) do
    case Floki.parse_document(html) do
      {:ok, document} ->
        document
        |> Floki.find("tr[id^='mod-quiz-report-overview-report']")
        |> Enum.map(fn tr ->
          student_cell = tr |> Floki.find("td[class*='sticky-column']") |> List.first()

          case student_cell do
            nil -> %{name: nil, url: nil, summary: nil}
            cell ->
              name = cell
              |> Floki.find("a")
              |> List.first()
              |> Floki.text()
              |> String.trim()

            url = student_cell
            |> Floki.find("a")
            |> List.last()
            |> case do
                  nil -> nil
                  link -> Floki.attribute(link, "href") |> List.first()
                end

            grade_summary = tr |> Floki.find("td.c9") |> List.first() |> Floki.text() |> String.trim()

            %{name: name, url: url, summary: grade_summary}
          end
        end)
        |> Enum.filter(fn %{name: name, url: url, summary: _summary} -> name != nil and url != nil end)

      _ ->
        IO.inspect("error parsing html")
        []
    end
  end
end
