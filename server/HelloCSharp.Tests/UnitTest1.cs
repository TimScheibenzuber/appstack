using Xunit;

public class AutoTests
{
    [Fact]
    public void Fahren_ReturnsCorrectMessage()
    {
        var auto = new Auto { Marke = "BMW", Baujahr = 2023 };
        var result = auto.Fahren();

        Assert.Equal("Fahren!", result);
    }
}
