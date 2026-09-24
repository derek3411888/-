using System;
using System.IO;
using System.Threading;
class HandoffRecorderFixture {
    static void Main(string[] args) {
        Console.CancelKeyPress += (sender, e) => {
            e.Cancel = true;
            File.WriteAllText(args[0], "sealed");
            Environment.Exit(0);
        };
        File.WriteAllText(args[0], "recording");
        while (true) Thread.Sleep(100);
    }
}
