defmodule UpelWeb.LabLive do
  use UpelWeb, :live_view
  require HtmlEntities

  @impl true
  def mount(_params, _session, socket) do
    socket = socket
    |> assign(:extracted_data, [])
    |> assign(:html_content, nil)
    |> assign(:error, false)
    |> assign(:done, false)
    |> assign(:uploaded_cookies, nil)
    |> assign(:item, %{mark: "", comment: "", params: "", generated_mark: "", generated_comment: ""})
    |> assign(:position, nil)
    {:ok, socket}
  end

  @impl true
  def handle_info({:fetch_students, cookies, data}, socket) do
    case data do
      {:ok, html} ->
        extracted_data = extract_student_data(html)
        IO.inspect(extracted_data)
        {:noreply, socket
        |> assign(:uploaded_cookies, cookies)
        |> assign(:extracted_data, extracted_data)
      }
      {:error, error} ->
        {:noreply, socket |> assign(:error, error)}
    end
  end

  @impl true
  def handle_event("fetch_answers", %{"answer_url" => url, "position" => position}, socket) do
    item = %{mark: "", comment: "", params: "", generated_mark: "", generated_comment: ""}
    position = String.to_integer(position)
    userid = List.last(Regex.run(~r"userid=(\d+)", url))
    case UpelWeb.StudentsComponent.fetch_html(url, socket.assigns.uploaded_cookies) do

      {:ok, html} ->
        case extract_grade(html, userid, socket.assigns.uploaded_cookies) do
          {:ok, %{grade: grade, comment: comment, params: params, assignment_id: assignment_id}} ->
            item = item
            |> Map.put(:mark, grade)
            |> Map.put(:comment, comment)
            |> Map.put(:assignment_id, assignment_id)
            |> Map.put(:params, URI.encode_query(params))
            {:noreply, socket
            |> assign(:position, position)
            |> assign(:item, item)
            |> assign(:done, false)
            |> assign(:error, false)
            }
          {:error, error} ->
            {:noreply, socket |> assign(:error, error)}
        end
      {:error, error} ->
        {:noreply, socket |> assign(:error, error)}
    end
  end

  def handle_event("add_feedback", %{
        "params" => params,
        "mark" => mark,
        "comment" => comment,
        "assignment_id" => assignment_id}, socket) do

    params = URI.decode_query(params)
    IO.inspect(params)
    params = params
    |> Map.put("grade", mark)
    |> Map.put("assignfeedbackcomments_editor[text]", comment)
    |> Map.put("sendstudentnotifications", "true")
    url = "https://upel.agh.edu.pl/lib/ajax/service.php?sesskey=#{params["sesskey"]}&info=mod_assign_submit_grading_form"
    json_params = %{
      "methodname" => "mod_assign_submit_grading_form",
      "index" => 0,
      "args" => %{
        "assignmentid" => assignment_id,
        "jsonformdata" => "\"#{URI.encode_query(params)}\"",
        "userid" => String.to_integer(params["editpdf_source_userid"]),
      }
    }
    IO.inspect(json_params)

    case HTTPoison.post(url, Jason.encode!([json_params]), [{"Content-Type", "application/json"}, {"Cookie", socket.assigns.uploaded_cookies}]) do
      {:ok, %HTTPoison.Response{status_code: 200, body: _body}} ->
        IO.inspect(_body)
        IO.inspect("Feedback submitted successfully")
        {:noreply, socket |> assign(:done, true)}
      {:error, error} ->
        IO.inspect("Error submitting feedback: #{error}")
        {:noreply, socket |> assign(:error, error)}
      _ ->
        {:noreply, socket |> assign(:error, "Unknown error")}
    end
  end

  defp extract_grade(html, userid, cookies) do
    sesskey = List.last(Regex.run(~r"\"sesskey\":\"(.*?)\"", html))
    contextid = List.last(Regex.run(~r"\"contextid\":(.*?),", html))
    assignment_id = List.last(Regex.run(~r"assignmentid=\"(\d+)\"", html))
    url = "https://upel.agh.edu.pl/lib/ajax/service.php?sesskey=#{sesskey}&info=core_get_fragment"
    request = [%{
      index: 0,
      methodname: "core_get_fragment",
      args:
      %{
        component: "mod_assign",
        callback: "gradingpanel",
        contextid: contextid,
        args: [
          %{name: "userid", value: userid},
          %{name: "attemptnumber", value: -1},
          %{name: "jsonformdata", value: "\"\""}
        ]
      }
    }
    ]
    case HTTPoison.post(url, Jason.encode!(request), [{"Content-Type", "application/json"}, {"Cookie", cookies}]) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        # Process the response body as needed
        parsed_body = Jason.decode!(body)
        html = parsed_body |> List.first |> Map.get("data") |> Map.get("html")
        IO.inspect(html)
        case Floki.parse_document(html) do
          {:ok, document} ->
             grade = document
             |> Floki.find("#id_grade")
             |> List.first()
             |> Floki.attribute("value")
             |> List.first()

             IO.inspect(grade)

            comment = document
             |> Floki.find("#id_assignfeedbackcomments_editor")
             |> List.first()
             |> Floki.text()
             |> HtmlEntities.decode()
             |> String.replace("\\r", "\n")
             |> String.replace("\\n", "\n")
             |> Floki.text()

            IO.inspect(comment)

            inputs = document
            |> Floki.find("input")
            |> Enum.map(fn input ->
              name = input |> Floki.attribute("name") |> List.first()
              value = input |> Floki.attribute("value") |> List.first()
              {name, value}
            end)
            |> Enum.into(%{})
            IO.inspect(inputs)


        {:ok, %{grade: grade, comment: comment, params: inputs, assignment_id: assignment_id}}
      _ ->
        IO.inspect("error parsing html")
        {:error, %{error: "error parsing html"}}
    end

    end
  end

  defp extract_student_data(html) do
    case Floki.parse_document(html) do
      {:ok, document} ->
        document
        |> Floki.find("tr[id^='mod_assign_grading']")
        |> Enum.map(fn tr ->
          student_cell = tr |> Floki.find("td[class*='username']") |> List.first()

          case student_cell do
            nil -> %{name: nil, url: nil, grade: nil}
            cell ->
              name = cell
              |> Floki.find("a")
              |> List.first()
              |> Floki.text()
              |> String.trim()
              |> String.slice(2..-1)

            url = tr |> Floki.find("td.grade") |> Floki.find("a.dropdown-item") |> Floki.attribute("href") |> List.first()

            grade = tr |> Floki.find("td.grade") |> Floki.find("div[class*='w-100']") |> Floki.text() |> HtmlEntities.decode()

            %{name: name, url: url, grade: grade}
          end
        end)
        |> Enum.filter(fn %{name: name, url: url} -> name != nil and url != nil end)

      _ ->
        IO.inspect("error parsing html")
        []
    end
  end
end
