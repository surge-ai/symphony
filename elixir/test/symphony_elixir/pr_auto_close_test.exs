defmodule SymphonyElixir.Linear.PrAutoCloseTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.PrAutoClose

  describe "parse_pr_url/1" do
    test "parses canonical GitHub PR URL" do
      assert PrAutoClose.parse_pr_url("https://github.com/surge-ai/nth-prediction-market-viewer/pull/84") ==
               [{"surge-ai", "nth-prediction-market-viewer", 84}]
    end

    test "accepts http and trailing slash / suffix" do
      assert PrAutoClose.parse_pr_url("http://github.com/foo/bar/pull/1") == [{"foo", "bar", 1}]
      assert PrAutoClose.parse_pr_url("https://github.com/foo/bar/pull/12/files") == [{"foo", "bar", 12}]
      assert PrAutoClose.parse_pr_url("https://github.com/foo/bar/pull/12#discussion_r1") == [{"foo", "bar", 12}]
    end

    test "rejects non-PR URLs" do
      assert PrAutoClose.parse_pr_url("https://github.com/foo/bar/issues/12") == []
      assert PrAutoClose.parse_pr_url("https://github.com/foo/bar") == []
      assert PrAutoClose.parse_pr_url("https://gitlab.com/foo/bar/-/merge_requests/1") == []
      assert PrAutoClose.parse_pr_url("https://example.com/foo/bar/pull/1") == []
      assert PrAutoClose.parse_pr_url("not a url") == []
    end

    test "rejects invalid pull numbers" do
      assert PrAutoClose.parse_pr_url("https://github.com/foo/bar/pull/0") == []
      assert PrAutoClose.parse_pr_url("https://github.com/foo/bar/pull/abc") == []
    end

    test "rejects non-strings" do
      assert PrAutoClose.parse_pr_url(nil) == []
      assert PrAutoClose.parse_pr_url(123) == []
    end
  end
end
