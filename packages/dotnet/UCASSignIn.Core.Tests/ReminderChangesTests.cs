namespace UCASSignIn.Core.Tests;

public sealed class ReminderChangesTests
{
    static Reminder Item(string id, int minutes = 60) => new(id, "account", "course", "20260916", "Course", "Room", TestData.Now.AddMinutes(minutes));

    [Fact] public void IdenticalSemesterRefreshDoesNotTouchExistingAlarms()
    {
        var reminders = Enumerable.Range(0, 150).Select(i => Item(i.ToString(), i + 1)).ToArray();
        var changes = ReminderChanges.Create(reminders, reminders.Reverse(), TestData.Now);
        Assert.Equal(150, changes.Current.Count);
        Assert.Empty(changes.Cancel);
        Assert.Empty(changes.Schedule);
    }

    [Fact] public void ChangesCancelRemovedExpiredAndReplacedAlarmsOnly()
    {
        var keep = Item("keep"); var removed = Item("remove"); var old = Item("changed");
        var updated = old with { At = old.At.AddMinutes(5), Body = "New room" };
        var added = Item("new"); var expired = Item("expired", -1);
        var changes = ReminderChanges.Create([keep, removed, old, expired], [keep, updated, added, expired], TestData.Now);
        Assert.Equal(new[] { "changed", "expired", "remove" }, changes.Cancel.Select(r => r.Id).Order());
        Assert.Equal(new[] { "changed", "new" }, changes.Schedule.Select(r => r.Id).Order());
        Assert.Contains(updated, changes.Current);
        Assert.DoesNotContain(expired, changes.Current);
    }

    [Fact] public void RebootOrInterruptedUpdateRestoresAllFutureAlarms()
    {
        var old = Item("old"); var keep = Item("keep"); var added = Item("new"); var expired = Item("expired", -1);
        var changes = ReminderChanges.Create([old, keep, expired], [keep, added, expired], TestData.Now, restore: true);
        Assert.Equal(3, changes.Cancel.Count);
        Assert.Equal(new[] { "keep", "new" }, changes.Schedule.Select(r => r.Id).Order());
    }
}
