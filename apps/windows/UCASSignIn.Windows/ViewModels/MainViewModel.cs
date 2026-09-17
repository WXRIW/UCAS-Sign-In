using UCASSignIn.Core;
using UCASSignIn.Windows.Services;
namespace UCASSignIn.Windows.ViewModels;

public sealed class MainViewModel
{
    public string Root { get; }
    public AccountCoordinator Model
    {
        get;
    }
    public bool HideIdentity
    {
        get; set;
    }
    public string Theme { get; set; } = "system";
    public MainViewModel()
    {
        Root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "UCASSignIn");
        IReminderScheduler reminders = new WindowsReminderScheduler();
        var store = new FileDataStore(Path.Combine(Root, "data"));
        Model = new(new SchoolClient(), new WindowsAccountStore(Path.Combine(Root, "accounts.dat")), store, store, reminders);
        var prefs = AtomicFile.ReadJson<Appearance>(Path.Combine(Root, "appearance.json"));
        HideIdentity = prefs?.HideIdentity ?? false;
        Theme = prefs?.Theme ?? "system";
    }
    public string Identity(StoredAccount a) => HideIdentity ? "同学 · 学号已隐藏" : $"{a.Session.Name ?? "同学"} · {a.Id}";
    public void SaveAppearance() => AtomicFile.WriteJson(Path.Combine(Root, "appearance.json"), new Appearance(HideIdentity, Theme));
    public sealed record Appearance(bool HideIdentity, string Theme);
}
