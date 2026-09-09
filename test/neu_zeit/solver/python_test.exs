defmodule NeuZeit.Solver.PythonTest do
  use ExUnit.Case, async: false

  @tag timeout: 60_000
  test "Python search regressions and exhaustive model comparisons" do
    {output, status} =
      System.cmd(
        "uv",
        [
          "run",
          "--locked",
          "--project",
          "priv/solver",
          "python",
          "-m",
          "unittest",
          "discover",
          "-s",
          "priv/solver",
          "-p",
          "test_solve.py"
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end
end
