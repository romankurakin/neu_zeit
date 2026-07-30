defmodule NeuZeit.Catalog.WeekPatternTest do
  use ExUnit.Case, async: true

  alias NeuZeit.Catalog.WeekPattern

  describe "normalize/1" do
    test "coerces, de-duplicates, and sorts week numbers" do
      assert {:ok, [1, 2, 3]} = WeekPattern.normalize(["3", 1, 2, "2"])
    end

    test "rejects empty and invalid masks" do
      assert {:error, :empty} = WeekPattern.normalize([])
      assert {:error, :invalid} = WeekPattern.normalize([1, "week two"])
    end
  end

  describe "validate/2" do
    test "returns a normalized mask within the term bounds" do
      assert {:ok, [1, 2, 3]} = WeekPattern.validate([3, 1, 2, 2], 4)
    end

    test "rejects weeks outside the term" do
      assert {:error, :out_of_bounds} = WeekPattern.validate([1, 5], 4)
    end

    test "raises from validate!/2 for an invalid mask" do
      assert_raise ArgumentError, "invalid week mask: :out_of_bounds", fn ->
        WeekPattern.validate!([1, 5], 4)
      end
    end
  end

  test "builds all, odd, even, and bounded week selections" do
    assert WeekPattern.all(5) == [1, 2, 3, 4, 5]
    assert WeekPattern.odd(5) == [1, 3, 5]
    assert WeekPattern.even(5) == [2, 4]
    assert WeekPattern.block(2, 4, 5) == [2, 3, 4]
  end

  test "detects overlapping week masks" do
    assert WeekPattern.overlap?([1, 3], [3, 4])
    refute WeekPattern.overlap?([1, 3], [2, 4])
  end
end
