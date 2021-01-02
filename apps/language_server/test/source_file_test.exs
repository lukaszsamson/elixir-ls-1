defmodule ElixirLS.LanguageServer.SourceFileTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ElixirLS.LanguageServer.SourceFile

  test "format_spec/2 with nil" do
    assert SourceFile.format_spec(nil, []) == ""
  end

  test "format_spec/2 with empty string" do
    assert SourceFile.format_spec("", []) == ""
  end

  test "format_spec/2 with a plain string" do
    spec = "@spec format_spec(String.t(), keyword()) :: String.t()"

    assert SourceFile.format_spec(spec, line_length: 80) == """

           ```
           @spec format_spec(String.t(), keyword()) :: String.t()
           ```
           """
  end

  test "format_spec/2 with a spec that needs to be broken over lines" do
    spec = "@spec format_spec(String.t(), keyword()) :: String.t()"

    assert SourceFile.format_spec(spec, line_length: 30) == """

           ```
           @spec format_spec(
             String.t(),
             keyword()
           ) :: String.t()
           ```
           """
  end

  def new(text) do
    %SourceFile{text: text, version: 0}
  end

  describe "apply_content_changes" do
    # tests and helper functions ported from https://github.com/microsoft/vscode-languageserver-node
    # note thet those functions are not production quality e.g. they don't deal with utf8/utf16 encoding issues
    defp index_of(string, substring) do
      case String.split(string, substring, parts: 2) do
        [left, _] -> String.to_charlist(left) |> length
        [_] -> -1
      end
    end

    def get_line_offsets(""), do: %{0 => 0}

    def get_line_offsets(text) do
      chars =
        text
        |> String.to_charlist()

      shifted =
        chars
        |> tl
        |> Kernel.++([nil])

      Enum.zip(chars, shifted)
      |> Enum.with_index()
      |> Enum.reduce({[0], nil}, fn
        _, {acc, :skip} ->
          {acc, nil}

        {{g, gs}, i}, {acc, nil} when g in [?\r, ?\n] ->
          if g == ?\r and gs == ?\n do
            {[i + 2 | acc], :skip}
          else
            {[i + 1 | acc], nil}
          end

        _, {acc, nil} ->
          {acc, nil}
      end)
      |> elem(0)
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.map(fn {off, ind} -> {ind, off} end)
      |> Enum.into(%{})
    end

    defp find_low_high(low, high, offset, line_offsets) when low < high do
      mid = floor((low + high) / 2)

      if line_offsets[mid] > offset do
        find_low_high(low, mid, offset, line_offsets)
      else
        find_low_high(mid + 1, high, offset, line_offsets)
      end
    end

    defp find_low_high(low, _high, _offset, _line_offsets), do: low

    def position_at(text, offset) do
      offset = max(min(offset, String.to_charlist(text) |> length), 0)

      line_offsets = get_line_offsets(text)
      low = 0
      high = map_size(line_offsets)

      if high == 0 do
        %{"line" => 0, "character" => offset}
      else
        low = find_low_high(low, high, offset, line_offsets)

        # low is the least x for which the line offset is larger than the current offset
        # or array.length if no line offset is larger than the current offset
        line = low - 1
        %{"line" => line, "character" => offset - line_offsets[line]}
      end
    end

    def position_create(l, c) do
      %{"line" => l, "character" => c}
    end

    def position_after_substring(text, sub_text) do
      index = index_of(text, sub_text)
      position_at(text, index + (String.to_charlist(sub_text) |> length))
    end

    def range_for_substring(source_file, sub_text) do
      index = index_of(source_file.text, sub_text)

      %{
        "start" => position_at(source_file.text, index),
        "end" => position_at(source_file.text, index + (String.to_charlist(sub_text) |> length))
      }
    end

    def range_after_substring(source_file, sub_text) do
      pos = position_after_substring(source_file.text, sub_text)
      %{"start" => pos, "end" => pos}
    end

    def range_create(sl, sc, el, ec) do
      %{"start" => position_create(sl, sc), "end" => position_create(el, ec)}
    end

    test "empty update" do
      assert %SourceFile{text: "abc123", version: 0} =
               SourceFile.apply_content_changes(new("abc123"), [])
    end

    test "full update" do
      assert %SourceFile{text: "efg456", version: 1} =
               SourceFile.apply_content_changes(new("abc123"), [%{"text" => "efg456"}])

      assert %SourceFile{text: "world", version: 2} =
               SourceFile.apply_content_changes(new("abc123"), [
                 %{"text" => "hello"},
                 %{"text" => "world"}
               ])
    end

    test "incrementally removing content" do
      sf = new("function abc() {\n  console.log(\"hello, world!\");\n}")

      assert %SourceFile{text: "function abc() {\n  console.log(\"\");\n}", version: 1} =
               SourceFile.apply_content_changes(sf, [
                 %{
                   "text" => "",
                   "range" => range_for_substring(sf, "hello, world!")
                 }
               ])
    end

    test "incrementally removing multi-line content" do
      sf = new("function abc() {\n  foo();\n  bar();\n  \n}")

      assert %SourceFile{text: "function abc() {\n  \n}", version: 1} =
               SourceFile.apply_content_changes(sf, [
                 %{
                   "text" => "",
                   "range" => range_for_substring(sf, "  foo();\n  bar();\n")
                 }
               ])
    end

    test "incrementally removing multi-line content 2" do
      sf = new("function abc() {\n  foo();\n  bar();\n  \n}")

      assert %SourceFile{text: "function abc() {\n  \n  \n}", version: 1} =
               SourceFile.apply_content_changes(sf, [
                 %{
                   "text" => "",
                   "range" => range_for_substring(sf, "foo();\n  bar();")
                 }
               ])
    end

    test "incrementally adding content" do
      sf = new("function abc() {\n  console.log(\"hello\");\n}")

      assert %SourceFile{
               text: "function abc() {\n  console.log(\"hello, world!\");\n}",
               version: 1
             } =
               SourceFile.apply_content_changes(sf, [
                 %{
                   "text" => ", world!",
                   "range" => range_after_substring(sf, "hello")
                 }
               ])
    end

    test "incrementally adding multi-line content" do
      sf = new("function abc() {\n  while (true) {\n    foo();\n  };\n}")

      assert %SourceFile{
               text: "function abc() {\n  while (true) {\n    foo();\n    bar();\n  };\n}",
               version: 1
             } =
               SourceFile.apply_content_changes(sf, [
                 %{
                   "text" => "\n    bar();",
                   "range" => range_after_substring(sf, "foo();")
                 }
               ])
    end

    test "incrementally replacing single-line content, more chars" do
      sf = new("function abc() {\n  console.log(\"hello, world!\");\n}")

      assert %SourceFile{
               text: "function abc() {\n  console.log(\"hello, test case!!!\");\n}",
               version: 1
             } =
               SourceFile.apply_content_changes(sf, [
                 %{
                   "text" => "hello, test case!!!",
                   "range" => range_for_substring(sf, "hello, world!")
                 }
               ])
    end

    test "incrementally replacing single-line content, less chars" do
      sf = new("function abc() {\n  console.log(\"hello, world!\");\n}")

      assert %SourceFile{text: "function abc() {\n  console.log(\"hey\");\n}", version: 1} =
               SourceFile.apply_content_changes(sf, [
                 %{
                   "text" => "hey",
                   "range" => range_for_substring(sf, "hello, world!")
                 }
               ])
    end

    test "incrementally replacing single-line content, same num of chars" do
      sf = new("function abc() {\n  console.log(\"hello, world!\");\n}")

      assert %SourceFile{
               text: "function abc() {\n  console.log(\"world, hello!\");\n}",
               version: 1
             } =
               SourceFile.apply_content_changes(sf, [
                 %{
                   "text" => "world, hello!",
                   "range" => range_for_substring(sf, "hello, world!")
                 }
               ])
    end

    test "incrementally replacing multi-line content, more lines" do
      sf = new("function abc() {\n  console.log(\"hello, world!\");\n}")

      assert %SourceFile{
               text: "\n//hello\nfunction d(){\n  console.log(\"hello, world!\");\n}",
               version: 1
             } =
               SourceFile.apply_content_changes(sf, [
                 %{
                   "text" => "\n//hello\nfunction d(){",
                   "range" => range_for_substring(sf, "function abc() {")
                 }
               ])
    end

    test "incrementally replacing multi-line content, less lines" do
      sf = new("a1\nb1\na2\nb2\na3\nb3\na4\nb4\n")

      assert %SourceFile{text: "a1\nb1\na2\nb2xx\nyy", version: 1} =
               SourceFile.apply_content_changes(sf, [
                 %{
                   "text" => "xx\nyy",
                   "range" => range_for_substring(sf, "\na3\nb3\na4\nb4\n")
                 }
               ])
    end

    test "incrementally replacing multi-line content, same num of lines and chars" do
      sf = new("a1\nb1\na2\nb2\na3\nb3\na4\nb4\n")

      assert %SourceFile{text: "a1\nb1\n\nxx1\nxx2\nb3\na4\nb4\n", version: 1} =
               SourceFile.apply_content_changes(sf, [
                 %{
                   "text" => "\nxx1\nxx2",
                   "range" => range_for_substring(sf, "a2\nb2\na3")
                 }
               ])
    end

    test "incrementally replacing multi-line content, same num of lines but diff chars" do
      sf = new("a1\nb1\na2\nb2\na3\nb3\na4\nb4\n")

      assert %SourceFile{text: "a1\nb1\n\ny\n\nb3\na4\nb4\n", version: 1} =
               SourceFile.apply_content_changes(sf, [
                 %{
                   "text" => "\ny\n",
                   "range" => range_for_substring(sf, "a2\nb2\na3")
                 }
               ])
    end

    test "incrementally replacing multi-line content, huge number of lines" do
      sf = new("a1\ncc\nb1")
      text = for _ <- 1..20000, into: "", do: "\ndd"

      assert %SourceFile{text: res, version: 1} =
               SourceFile.apply_content_changes(sf, [
                 %{
                   "text" => text,
                   "range" => range_for_substring(sf, "\ncc")
                 }
               ])

      assert res == "a1" <> text <> "\nb1"
    end

    test "several incremental content changes" do
      sf = new("function abc() {\n  console.log(\"hello, world!\");\n}")

      assert %SourceFile{
               text: "function abcdefghij() {\n  console.log(\"hello, test case!!!\");\n}",
               version: 3
             } =
               SourceFile.apply_content_changes(sf, [
                 %{
                   "text" => "defg",
                   "range" => range_create(0, 12, 0, 12)
                 },
                 %{
                   "text" => "hello, test case!!!",
                   "range" => range_create(1, 15, 1, 28)
                 },
                 %{
                   "text" => "hij",
                   "range" => range_create(0, 16, 0, 16)
                 }
               ])
    end

    test "basic append" do
      sf = new("foooo\nbar\nbaz")

      assert %SourceFile{text: "foooo\nbar some extra content\nbaz", version: 1} =
               SourceFile.apply_content_changes(sf, [
                 %{
                   "text" => " some extra content",
                   "range" => range_create(1, 3, 1, 3)
                 }
               ])
    end

    test "multi-line append" do
      sf = new("foooo\nbar\nbaz")

      assert %SourceFile{text: "foooo\nbar some extra\ncontent\nbaz", version: 1} =
               SourceFile.apply_content_changes(sf, [
                 %{
                   "text" => " some extra\ncontent",
                   "range" => range_create(1, 3, 1, 3)
                 }
               ])
    end

    test "basic delete" do
      sf = new("foooo\nbar\nbaz")

      assert %SourceFile{text: "foooo\n\nbaz", version: 1} =
               SourceFile.apply_content_changes(sf, [
                 %{
                   "text" => "",
                   "range" => range_create(1, 0, 1, 3)
                 }
               ])
    end

    test "multi-line delete" do
      sf = new("foooo\nbar\nbaz")

      assert %SourceFile{text: "foooo\nbaz", version: 1} =
               SourceFile.apply_content_changes(sf, [
                 %{
                   "text" => "",
                   "range" => range_create(0, 5, 1, 3)
                 }
               ])
    end

    test "single character replace" do
      sf = new("foooo\nbar\nbaz")

      assert %SourceFile{text: "foooo\nbaz\nbaz", version: 1} =
               SourceFile.apply_content_changes(sf, [
                 %{
                   "text" => "z",
                   "range" => range_create(1, 2, 1, 3)
                 }
               ])
    end

    test "multi-character replace" do
      sf = new("foo\nbar")

      assert %SourceFile{text: "foo\nfoobar", version: 1} =
               SourceFile.apply_content_changes(sf, [
                 %{
                   "text" => "foobar",
                   "range" => range_create(1, 0, 1, 3)
                 }
               ])
    end

    test "windows line endings are preserved in document" do
      sf = new("foooo\r\nbar\rbaz")

      assert %SourceFile{text: "foooo\r\nbaz\rbaz", version: 1} =
               SourceFile.apply_content_changes(sf, [
                 %{
                   "text" => "z",
                   "range" => range_create(1, 2, 1, 3)
                 }
               ])
    end

    test "windows line endings are preserved in inserted text" do
      sf = new("foooo\nbar\nbaz")

      assert %SourceFile{text: "foooo\nbaz\r\nz\rz\nbaz", version: 1} =
               SourceFile.apply_content_changes(sf, [
                 %{
                   "text" => "z\r\nz\rz",
                   "range" => range_create(1, 2, 1, 3)
                 }
               ])
    end

    test "utf8 codons are preserved in document" do
      sf = new("foooo\nb🏳️‍🌈r\nbaz")

      assert %SourceFile{text: "foooo\nb🏳️‍🌈z\nbaz", version: 1} =
               SourceFile.apply_content_changes(sf, [
                 %{
                   "text" => "z",
                   "range" => range_create(1, 7, 1, 8)
                 }
               ])
    end

    test "utf8 codonss are preserved in inserted text" do
      sf = new("foooo\nbar\nbaz")

      assert %SourceFile{text: "foooo\nbaz🏳️‍🌈z\nbaz", version: 1} =
               SourceFile.apply_content_changes(sf, [
                 %{
                   "text" => "z🏳️‍🌈z",
                   "range" => range_create(1, 2, 1, 3)
                 }
               ])
    end

    test "invalid update range - before the document starts -> before the document starts" do
      sf = new("foo\nbar")

      assert %SourceFile{text: "abc123foo\nbar", version: 1} =
               SourceFile.apply_content_changes(sf, [
                 %{
                   "text" => "abc123",
                   "range" => range_create(-2, 0, -1, 3)
                 }
               ])
    end

    test "invalid update range - before the document starts -> the middle of document" do
      sf = new("foo\nbar")

      assert %SourceFile{text: "foobar\nbar", version: 1} =
               SourceFile.apply_content_changes(sf, [
                 %{
                   "text" => "foobar",
                   "range" => range_create(-1, 0, 0, 3)
                 }
               ])
    end

    test "invalid update range - the middle of document -> after the document ends" do
      sf = new("foo\nbar")

      assert %SourceFile{text: "foo\nfoobar", version: 1} =
               SourceFile.apply_content_changes(sf, [
                 %{
                   "text" => "foobar",
                   "range" => range_create(1, 0, 1, 10)
                 }
               ])
    end

    test "invalid update range - after the document ends -> after the document ends" do
      sf = new("foo\nbar")

      assert %SourceFile{text: "foo\nbarabc123", version: 1} =
               SourceFile.apply_content_changes(sf, [
                 %{
                   "text" => "abc123",
                   "range" => range_create(3, 0, 6, 10)
                 }
               ])
    end

    test "invalid update range - before the document starts -> after the document ends" do
      sf = new("foo\nbar")

      assert %SourceFile{text: "entirely new content", version: 1} =
               SourceFile.apply_content_changes(sf, [
                 %{
                   "text" => "entirely new content",
                   "range" => range_create(-1, 1, 2, 10000)
                 }
               ])
    end
  end

  test "lines" do
    assert [""] == SourceFile.lines("")
    assert ["abc"] == SourceFile.lines("abc")
    assert ["", ""] == SourceFile.lines("\n")
    assert ["a", ""] == SourceFile.lines("a\n")
    assert ["", "a"] == SourceFile.lines("\na")
    assert ["ABCDE", "FGHIJ"] == SourceFile.lines("ABCDE\rFGHIJ")
    assert ["ABCDE", "FGHIJ"] == SourceFile.lines("ABCDE\r\nFGHIJ")
    assert ["ABCDE", "", "FGHIJ"] == SourceFile.lines("ABCDE\n\nFGHIJ")
    assert ["ABCDE", "", "FGHIJ"] == SourceFile.lines("ABCDE\r\rFGHIJ")
    assert ["ABCDE", "", "FGHIJ"] == SourceFile.lines("ABCDE\n\rFGHIJ")
  end

  test "full_range" do
    assert %{
             "end" => %{"character" => 0, "line" => 0},
             "start" => %{"character" => 0, "line" => 0}
           } = SourceFile.full_range(new(""))

    assert %{"end" => %{"character" => 1, "line" => 0}} = SourceFile.full_range(new("a"))
    assert %{"end" => %{"character" => 0, "line" => 1}} = SourceFile.full_range(new("\n"))
    assert %{"end" => %{"character" => 2, "line" => 1}} = SourceFile.full_range(new("a\naa"))
    assert %{"end" => %{"character" => 2, "line" => 1}} = SourceFile.full_range(new("a\r\naa"))
    assert %{"end" => %{"character" => 8, "line" => 1}} = SourceFile.full_range(new("a\naa🏳️‍🌈"))
  end

  describe "lines_with_endings/1" do
    test "with an empty string" do
      assert SourceFile.lines_with_endings("") == [{"", nil}]
    end

    test "begining with endline" do
      assert SourceFile.lines_with_endings("\n") == [{"", "\n"}, {"", nil}]
      assert SourceFile.lines_with_endings("\nbasic") == [{"", "\n"}, {"basic", nil}]
    end

    test "without any endings" do
      assert SourceFile.lines_with_endings("basic") == [{"basic", nil}]
    end

    test "with a LF" do
      assert SourceFile.lines_with_endings("text\n") == [{"text", "\n"}, {"", nil}]
    end

    test "with a CR LF" do
      assert SourceFile.lines_with_endings("text\r\n") == [{"text", "\r\n"}, {"", nil}]
    end

    test "with a CR" do
      assert SourceFile.lines_with_endings("text\r") == [{"text", "\r"}, {"", nil}]
    end

    test "with multiple LF lines" do
      assert SourceFile.lines_with_endings("line1\nline2\nline3") == [
               {"line1", "\n"},
               {"line2", "\n"},
               {"line3", nil}
             ]
    end

    test "with multiple CR LF line endings" do
      text = "A\r\nB\r\n\r\nC"

      assert SourceFile.lines_with_endings(text) == [
               {"A", "\r\n"},
               {"B", "\r\n"},
               {"", "\r\n"},
               {"C", nil}
             ]
    end

    test "with an emoji" do
      text = "👨‍👩‍👦 test"
      assert SourceFile.lines_with_endings(text) == [{"👨‍👩‍👦 test", nil}]
    end

    test "example multi-byte string" do
      text = "𐂀"
      assert String.valid?(text)
      [{line, ending}] = SourceFile.lines_with_endings(text)
      assert String.valid?(line)
      assert ending in ["\r\n", "\n", "\r", nil]
    end

    property "always creates valid binaries" do
      check all(
              elements <-
                list_of(
                  one_of([
                    string(:printable),
                    one_of([constant("\r\n"), constant("\n"), constant("\r")])
                  ])
                )
            ) do
        text = List.to_string(elements)
        lines_w_endings = SourceFile.lines_with_endings(text)

        Enum.each(lines_w_endings, fn {line, ending} ->
          assert String.valid?(line)
          assert ending in ["\r\n", "\n", "\r", nil]
        end)
      end
    end
  end

  # tests basing on cases from https://github.com/microsoft/vscode-uri/blob/master/src/test/uri.test.ts
  describe "path_from_uri" do
    test "unix" do
      path = SourceFile.path_from_uri("file:///some/path")

      if is_windows() do
        assert path == "/some/path"
      else
        assert path == "/some/path"
      end

      path = SourceFile.path_from_uri("file:///some/path/")

      if is_windows() do
        assert path == "/some/path/"
      else
        assert path == "/some/path/"
      end

      path = SourceFile.path_from_uri("file:///nodes%2B%23.ex")
      assert path == "/nodes+#.ex"
    end

    test "UNC" do
      path = SourceFile.path_from_uri("file://shares/files/c%23/p.cs")

      if is_windows() do
        assert path == "\\\\shares\\files\\c#\\p.cs"
      else
        assert path == "//shares/files/c#/p.cs"
      end

      path = SourceFile.path_from_uri("file://monacotools1/certificates/SSL/")

      if is_windows() do
        assert path == "\\\\monacotools1\\certificates\\SSL\\"
      else
        assert path == "//monacotools1/certificates/SSL/"
      end
    end
    
    test "no `path` in URI" do
      path = SourceFile.path_from_uri("file://%2Fhome%2Fticino%2Fdesktop%2Fcpluscplus%2Ftest.cpp")

      if is_windows() do
        assert path == "\\"
      else
        assert path == "/"
      end
    end

    test "windows drive letter" do
      path = SourceFile.path_from_uri("file:///c:/test/me")

      if is_windows() do
        assert path == "c:\\test\\me"
      else
        assert path == "c:/test/me"
      end

      path = SourceFile.path_from_uri("file:///C:/test/me/")

      if is_windows() do
        assert path == "c:\\test\\me\\"
      else
        assert path == "c:/test/me/"
      end

      path = SourceFile.path_from_uri("file:///_:/path")

      if is_windows() do
        assert path == "\\_:\\path"
      else
        assert path == "/_:/path"
      end

      path = SourceFile.path_from_uri("file:///c:/Source/Z%C3%BCrich%20or%20Zurich%20(%CB%88zj%CA%8A%C9%99r%C9%AAk,/Code/resources/app/plugins")

      if is_windows() do
        assert path == "c:\\Source\\Zürich or Zurich (ˈzjʊərɪk,\\Code\\resources\\app\\plugins"
      else
        assert path == "c:/Source/Zürich or Zurich (ˈzjʊərɪk,/Code/resources/app/plugins"
      end
    end

    test "wrong schema" do
      assert_raise ArgumentError, fn ->
        SourceFile.path_from_uri("untitled:Untitled-1")
      end
      assert_raise ArgumentError, fn ->
        SourceFile.path_from_uri("unsaved://343C3EE7-D575-486D-9D33-93AFFAF773BD")
      end
    end
  end

  # tests basing on cases from https://github.com/microsoft/vscode-uri/blob/master/src/test/uri.test.ts
  describe "path_to_uri" do
    test "basic" do
      assert "file:///nodes%2B%23.ex" == SourceFile.path_to_uri("/nodes+#.ex")
      assert "file:///coding/c%23/project1" == SourceFile.path_to_uri("/coding/c#/project1")

      assert "file:///a.file" == SourceFile.path_to_uri("a.file")

      assert "file:///Users/jrieken/Code/_samples/18500/M%C3%B6del%20%2B%20Other%20Th%C3%AEng%C3%9F/model.js" == SourceFile.path_to_uri("/Users/jrieken/Code/_samples/18500/Mödel + Other Thîngß/model.js")

      assert "file:///./foo/bar" == SourceFile.path_to_uri("./foo/bar")
      assert "file:///foo/%25A0.txt" == SourceFile.path_to_uri("/foo/%A0.txt")
      assert "file:///foo/%252e.txt" == SourceFile.path_to_uri("/foo/%2e.txt")
    end

    test "windows path" do
      assert "file:///c%3A/win/path" == SourceFile.path_to_uri("c:/win/path")
      assert "file:///c%3A/win/path" == SourceFile.path_to_uri("C:/win/path")
      assert "file:///c%3A/win/path/" == SourceFile.path_to_uri("c:/win/path/")
      assert "file:///c%3A/win/path" == SourceFile.path_to_uri("/c:/win/path")

      if is_windows() do
        assert "file:///c%3A/win/path" == SourceFile.path_to_uri("c:\\win\\path")
        assert "file:///c%3A/win/path" == SourceFile.path_to_uri("c:\\win/path")

        assert "file:///c%3A/test%20with%20%25/path" == SourceFile.path_to_uri("c:\\test with %\\path")
        assert "file:///c%3A/test%20with%20%2525/c%23code" == SourceFile.path_to_uri("c:\\test with %25\\c#code")
      else
        assert "file:///c%3A%5Cwin%5Cpath" == SourceFile.path_to_uri("c:\\win\\path")
        assert "file:///c%3A%5Cwin/path" == SourceFile.path_to_uri("c:\\win/path")
      end
    end

    test "UNC path" do
      if is_windows() do
        assert "file://sh%C3%A4res/path/c%23/plugin.json" == SourceFile.path_to_uri("\\\\shäres\\path\\c#\\plugin.json")
        assert "file://localhost/c%24/GitDevelopment/express" == SourceFile.path_to_uri("\\\\localhost\\c$\\GitDevelopment\\express")
      else
        assert "file:///%5C%5Csh%C3%A4res%5Cpath%5Cc%23%5Cplugin.json" == SourceFile.path_to_uri("\\\\shäres\\path\\c#\\plugin.json")
        assert "file:///%5C%5Clocalhost%5Cc%24%5CGitDevelopment%5Cexpress" == SourceFile.path_to_uri("\\\\localhost\\c$\\GitDevelopment\\express")
      end
    end
  end

  defp is_windows() do
    case :os.type() do
      {:win32, _} -> true
      _ -> false
    end
  end
end
