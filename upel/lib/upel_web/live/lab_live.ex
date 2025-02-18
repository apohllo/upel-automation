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
    |> assign(:content, nil)
    {:ok, socket}
  end

  @impl true
  def handle_info({:fetch_students, cookies, data}, socket) do
    case data do
      {:ok, html} ->
        extracted_data = extract_student_data(html)
        {:noreply, socket
        |> assign(:uploaded_cookies, cookies)
        |> assign(:extracted_data, extracted_data)
      }
      {:error, error} ->
        {:noreply, socket |> assign(:error, error)}
    end
  end


  @impl true
  def handle_event("fetch_answers", %{"answer_url" => url, "position" => position, "files" => files, "names" => names}, socket) do
    item = %{mark: "", comment: "", params: "", generated_mark: "", generated_comment: ""}
    position = String.to_integer(position)
    userid = List.last(Regex.run(~r"userid=(\d+)", url))
    case UpelWeb.StudentsComponent.fetch_html(url, socket.assigns.uploaded_cookies) do
      {:ok, html} ->
        case extract_grade(html, userid, socket.assigns.uploaded_cookies) do
          {:ok, %{grade: grade, comment: comment, params: params, assignment_id: assignment_id}} ->
            solutions = List.zip([files, names])
            |> Enum.filter(fn {_, name} -> Regex.match?(~r/\.ipynb$/, name) end)
            |> Enum.map(fn {link, _name} ->
              case extract_solution(link, socket.assigns.uploaded_cookies) do
                {:ok, inputs_outputs} ->
                  inputs_outputs
                {:error} ->
                  [%{input: "Error extracting solution", outputs: ""}]
                error ->
                  IO.inspect(error)
                  [%{input: "Error extracting solution", outputs: ""}]
              end
            end)

            item = item
            |> Map.put(:mark, grade)
            |> Map.put(:comment, comment)
            |> Map.put(:assignment_id, assignment_id)
            |> Map.put(:files, files)
            |> Map.put(:names, names)
            |> Map.put(:params, URI.encode_query(params))
            |> Map.put(:solutions, solutions)
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

    case HTTPoison.post(url, Jason.encode!([json_params]), [{"Content-Type", "application/json"}, {"Cookie", socket.assigns.uploaded_cookies}]) do
      {:ok, %HTTPoison.Response{status_code: 200, body: _body}} ->
        {:noreply, socket |> assign(:done, true)}
      {:error, error} ->
        IO.inspect("Error submitting feedback: #{error}")
        {:noreply, socket |> assign(:error, error)}
      _ ->
        {:noreply, socket |> assign(:error, "Unknown error")}
    end
  end

  defp extract_solution(link, cookies) do
    case HTTPoison.get(link,[{"Cookie", cookies}]) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        cells = body
        |> Jason.decode!()
        |> Map.get("cells")
        filtered_cells = cells
        |> Enum.filter(fn cell ->
          accepted_cell_type?(cell, ["code", "markdown"]) &&
          accepted_cell_tags?(cell, ["ex"])
        end)

        cells =
        if length(filtered_cells) != 0 do
          filtered_cells
        else
          cells
        end
        |> Enum.map(fn cell ->
          convert_cell(cell)
        end)

        {:ok, cells}
      _ ->
        {:error}
    end
  end

  defp convert_cell(%{"cell_type" => "markdown", "source" => source}) do
    case Earmark.as_html(source, breaks: true) do
      {:ok, html, _} ->
        %{input: html|> Phoenix.HTML.raw(), outputs: "", type: "markdown"}
      {:error, _html, error_messages} ->
        %{input: "Error converting markdown: #{inspect(error_messages)}", outputs: [], type: "markdown"}
    end
  end

  defp convert_cell(%{"cell_type" => "code", "source" => source, "outputs" => outputs}) do
    source = Makeup.highlight(List.foldl(source, "", fn line, acc -> acc <> line end),
      lexer: MakeupSyntect.Lexer,
      lexer_options: [language: "Python"],
      formatter_options: [css_class: "highlight", highlight_tag: "span"]
    )
    outputs = outputs
    |> Enum.map(fn output -> convert_output(output) end)
    %{input: source |> Phoenix.HTML.raw(), outputs: outputs, type: "code"}
  end

  defp convert_output(%{"output_type" => "stream", "name" => "stdout", "text" => text}) do
    text =
      if(Enum.count(text) > 30) do
        Enum.take(text, 30) ++ ["..."]
      else
        text
      end
    output = List.foldl(text, "", fn line, acc -> acc <> "<br/>" <> (Phoenix.HTML.html_escape(line) |> safe_to_string()) end) |> Phoenix.HTML.raw()
    %{content: output, type: "html"}
  end

  defp convert_output(%{"output_type" => "stream", "name" => "stderr", "text" => text}) do
    text =
      if(Enum.count(text) > 30) do
        Enum.take(text, 30) ++ ["..."]
      else
        text
      end
    output = List.foldl(text, "", fn line, acc -> acc <> "<br/>" <> (Phoenix.HTML.html_escape(line) |> safe_to_string()) end) |> Phoenix.HTML.raw()
    %{content: output, type: "html"}
  end

  defp convert_output(%{"output_type" => "display_data", "data" => data}) do
    case data do
      %{"image/png" => content} ->
        %{content: "data:image/png;base64,#{content}", type: "image"}
      %{"text/html" => content} ->
        %{content: content |> Phoenix.HTML.raw(), type: "html"}
      %{"text/plain" => content} ->
        %{content: List.foldl(content, "", fn line, acc -> acc <> "<br/>" <> (Phoenix.HTML.html_escape(line) |> safe_to_string()) end) |> Phoenix.HTML.raw(), type: "html"}
      _ ->
        %{content: "Unknown display data", type: "unknown"}
    end
  end

  defp convert_output(%{"output_type" => "execute_result", "data" => data}) do
    case data do
      %{"text/plain" => content} ->
        %{content: List.foldl(content, "<code>", fn line, acc -> acc <> "<br/>" <> (Phoenix.HTML.html_escape(line) |> safe_to_string()) end) <> "</code>" |> Phoenix.HTML.raw(), type: "html"}
      _ ->
        %{content: "Unknown display data", type: "unknown"}
    end
  end

  defp convert_output(%{"output_type" => "error", "ename" => ename, "evalue" => evalue, "traceback" => traceback}) do
    %{content: "Error: #{ename} - #{evalue}", type: "html"}
  end

  defp convert_output(params) do
    output = "#{params["output_type"]}"
    IO.inspect(params)
    %{content: output, type: "unknown"}
  end


  defp accepted_cell_tags?(cell, tags) do
    tags
    |> Enum.any?(fn tag ->
      cell
      |> Map.get("metadata", %{})
      |> Map.get("tags", [])
      |> Enum.any?(fn t -> t == tag end)
    end)
  end

  defp accepted_cell_type?(cell, types) do
    types
    |> Enum.any?(fn type ->
      cell
      |> Map.get("cell_type") == type
    end)
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
        case Floki.parse_document(html) do
          {:ok, document} ->
             grade = document
             |> Floki.find("#id_grade")
             |> List.first()
             |> Floki.attribute("value")
             |> List.first()


            comment = document
             |> Floki.find("#id_assignfeedbackcomments_editor")
             |> List.first()
             |> Floki.text()
             |> HtmlEntities.decode()
             |> String.replace("\\r", "\n")
             |> String.replace("\\n", "\n")
             |> Floki.text()


            inputs = document
            |> Floki.find("input")
            |> Enum.map(fn input ->
              name = input |> Floki.attribute("name") |> List.first()
              value = input |> Floki.attribute("value") |> List.first()
              {name, value}
            end)
            |> Enum.into(%{})


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
            nil -> %{name: nil, url: nil, grade: nil, notebooks: [], overdue: nil}
            cell ->
              name = cell
              |> Floki.find("a")
              |> List.first()
              |> Floki.text()
              |> String.trim()

              initials = cell
              |> Floki.find("a > span")
              |> List.first()
              |> Floki.text()
              |> String.trim()

              name = String.slice(name, String.length(initials)..-1//1)

            url = tr |> Floki.find("td.grade") |> Floki.find("a.dropdown-item") |> Floki.attribute("href") |> List.first()

            grade = tr |> Floki.find("td.grade") |> Floki.find("div[class*='w-100']") |> Floki.text() |> HtmlEntities.decode()

            links = tr |> Floki.find("div[class*='fileuploadsubmission'] > a") #|> Floki.attribute("href")
            urls = links |> Floki.attribute("href")
            names = links |> Enum.map(fn el -> el |> Floki.text() end)
            notebooks = List.zip([urls, names])

            overdue = tr |> Floki.find("div[class*='submissioninfo'] div") |> Enum.map(fn el -> el |> Floki.text() end) |> List.foldl("", fn el, acc -> acc <> " " <> el end)

            %{name: name, url: url, grade: grade, notebooks: notebooks, overdue: overdue}
          end
        end)
        |> Enum.filter(fn %{name: name, url: url} -> name != nil and url != nil end)

      _ ->
        IO.inspect("error parsing html")
        []
    end
  end
end

defmodule MyAppWeb.MarkdownHelper do
end
