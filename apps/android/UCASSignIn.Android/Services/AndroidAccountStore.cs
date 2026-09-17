using Android.Security.Keystore;
using Java.Security;
using Javax.Crypto;
using Javax.Crypto.Spec;
using UCASSignIn.Core;
namespace UCASSignIn.Android.Services;

public sealed class AndroidAccountStore(string path) : EncryptedAccountStore(path)
{
    const string Alias = "ucas-signin.accounts.v1";
    IKey Key(bool create)
    {
        using var store = KeyStore.GetInstance("AndroidKeyStore")!;
        store.Load(null);
        if (!store.ContainsAlias(Alias))
        {
            if (!create)
                throw new IOException("账户加密密钥不可用，原始数据已保留");
            using var generator = KeyGenerator.GetInstance(KeyProperties.KeyAlgorithmAes, "AndroidKeyStore")!;
            using var spec = new KeyGenParameterSpec.Builder(Alias, KeyStorePurpose.Encrypt | KeyStorePurpose.Decrypt)
                .SetBlockModes(KeyProperties.BlockModeGcm)!.SetEncryptionPaddings(KeyProperties.EncryptionPaddingNone)!.SetKeySize(256)!.Build();
            generator.Init(spec);
            generator.GenerateKey();
        }
        return store.GetKey(Alias, null)!;
    }
    protected override byte[] Protect(byte[] plain)
    {
        using var cipher = Cipher.GetInstance("AES/GCM/NoPadding")!;
        using var key = Key(true);
        cipher.Init(CipherMode.EncryptMode, key);
        return cipher.GetIV()!.Concat(cipher.DoFinal(plain)!).ToArray();
    }
    protected override byte[] Unprotect(byte[] bytes)
    {
        if (bytes.Length < 28)
            throw new IOException("账户文件不完整");
        using var cipher = Cipher.GetInstance("AES/GCM/NoPadding")!;
        using var key = Key(false);
        using var spec = new GCMParameterSpec(128, bytes[..12]);
        cipher.Init(CipherMode.DecryptMode, key, spec);
        return cipher.DoFinal(bytes[12..])!;
    }
}
