using Android.Content;
using UCASSignIn.Core;
using UCASSignIn.Android.Services;
namespace UCASSignIn.Android.ViewModels;

public sealed class MainViewModel
{
    static MainViewModel? instance;
    public static MainViewModel Get(Context context) => instance ??= new(context.ApplicationContext!);
    readonly ISharedPreferences prefs;
    public AccountCoordinator Model
    {
        get;
    }
    public int Page
    {
        get; set;
    }
    public string?[] Routes { get; } = new string?[4];
    public Course?[] Details { get; } = new Course?[4];
    public CatalogCourse?[] CatalogDetails { get; } = new CatalogCourse?[4];
    public bool HideIdentity
    {
        get => prefs.GetBoolean("hide", false); set => prefs.Edit()!.PutBoolean("hide", value)!.Apply();
    }
    public string Theme
    {
        get => prefs.GetString("theme", "system")!; set => prefs.Edit()!.PutString("theme", value)!.Apply();
    }
    public bool AutoCheckUpdates
    {
        get => prefs.GetBoolean("autoCheckUpdates", true); set => prefs.Edit()!.PutBoolean("autoCheckUpdates", value)!.Apply();
    }
    MainViewModel(Context context)
    {
        prefs = context.GetSharedPreferences("appearance", FileCreationMode.Private)!;
        var root = context.FilesDir!.AbsolutePath;
        var store = new FileDataStore(Path.Combine(root, "data"));
        Model = new(new SchoolClient(), new AndroidAccountStore(Path.Combine(root, "accounts.dat")), store, store, new AndroidReminderScheduler(context));
    }
    public string Identity(StoredAccount a) => HideIdentity ? "同学 · 学号已隐藏" : $"{a.Session.Name ?? "同学"} · {a.Id}";
}
