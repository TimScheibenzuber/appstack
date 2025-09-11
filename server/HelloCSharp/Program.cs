// using = Bibliotheken einbinden (vergleichbar mit "import" in Python)
using System;

// Das sind "Top-Level Statements": Einstiegspunkt ohne extra Main-Methode.
Console.WriteLine("Hallo Tim!");
// Variablen sind typisiert: int = ganze Zahl
int a = 3;
int b = 4;
int summe = a + b;
Console.WriteLine($"Summe: {summe}");
// $"..." = Stringinterpolation (Variablen im Text)