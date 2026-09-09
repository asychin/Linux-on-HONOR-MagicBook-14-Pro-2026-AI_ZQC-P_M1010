using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32;

internal static class Program
{
    private static readonly IDictionary<string, Tuple<byte, byte, byte>> Commands =
        new Dictionary<string, Tuple<byte, byte, byte>>(StringComparer.OrdinalIgnoreCase)
        {
            { "gtub", Tuple.Create((byte)0x04, (byte)0x0e, (byte)0) },
            { "gfci", Tuple.Create((byte)0x07, (byte)0x0b, (byte)0) },
            { "gvrf", Tuple.Create((byte)0x07, (byte)0x10, (byte)0) },
            { "fan0", Tuple.Create((byte)0x02, (byte)0x08, (byte)0) },
            { "fan1", Tuple.Create((byte)0x02, (byte)0x08, (byte)1) },
            { "godp", Tuple.Create((byte)0x03, (byte)0x0e, (byte)0) },
            { "gppt", Tuple.Create((byte)0x03, (byte)0x0b, (byte)0) }
        };

    private static int Main(string[] args)
    {
        try
        {
            EnsureSupportedMachine();
            string pcManagerDir = Environment.GetEnvironmentVariable("HONOR_PCMANAGER_DIR");
            if (string.IsNullOrEmpty(pcManagerDir))
                pcManagerDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "HONOR", "PCManager");
            string[] names = args.Length == 0 ? Commands.Keys.ToArray() : args;
            if (names.Any(name => !Commands.ContainsKey(name)))
            {
                Console.Error.WriteLine("Usage: HonorWmiRead [gtub] [gfci] [gvrf] [fan0] [fan1] [godp] [gppt]");
                return 2;
            }

            using (var wmi = new HonorWmi(pcManagerDir))
            {
                foreach (string name in names)
                {
                    if (name.Equals("godp", StringComparison.OrdinalIgnoreCase))
                    {
                        PrintGodp(wmi);
                        continue;
                    }
                    Tuple<byte, byte, byte> command = Commands[name];
                    Print(name, wmi.Read(command.Item1, command.Item2, command.Item3));
                }
            }
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine("error: " + exception.Message);
            return 1;
        }
    }

    private static void EnsureSupportedMachine()
    {
        string product = Registry.GetValue(
            @"HKEY_LOCAL_MACHINE\HARDWARE\DESCRIPTION\System\BIOS",
            "SystemProductName",
            null) as string;
        if (!string.Equals(product, "ZQC-P", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("unsupported SystemProductName: " + (product ?? "<missing>"));
    }

    private static void Print(string name, byte[] output)
    {
        Console.WriteLine("{0}: status=0x{1:X2}", name.ToUpperInvariant(), output[0]);
        switch (name.ToLowerInvariant())
        {
            case "gtub":
                string mode = output[1] == 0 ? "Smart" : output[1] == 1 ? "Performance" : "unknown";
                Console.WriteLine("  CRWM=0x{0:X2} ({1})", output[1], mode);
                break;
            case "gfci":
                Console.WriteLine("  FTSL=0x{0:X2}", output[1]);
                break;
            case "gvrf":
                Console.WriteLine("  VRMS=0x{0:X2} PPL4=0x{1:X2}", output[1], output[0x0e]);
                string[] labels = { "VR10", "VR12", "VR14", "VR16", "GFP0", "GFP2", "GFP3", "GFF0" };
                for (int i = 0; i < labels.Length; i++)
                {
                    ushort value = BitConverter.ToUInt16(output, 0x0f + i * 2);
                    Console.WriteLine("  {0}=0x{1:X4} ({1})", labels[i], value);
                }
                break;
            case "fan0":
            case "fan1":
                Console.WriteLine("  RPM={0}", BitConverter.ToUInt16(output, 1));
                break;
            case "gppt":
                Console.WriteLine("  PL1M=0x{0:X2} PL1R=0x{1:X2} PL2R=0x{2:X2} PL4R=0x{3:X4}",
                    output[1], output[2], output[3], BitConverter.ToUInt16(output, 4));
                Console.WriteLine("  P1RT=0x{0:X4} ({0}) P2RT=0x{1:X4} ({1})",
                    BitConverter.ToUInt16(output, 6), BitConverter.ToUInt16(output, 8));
                break;
        }
        Console.WriteLine("  raw[0..31]=" + ToHex(output, 32));
    }

    private static void PrintGodp(HonorWmi wmi)
    {
        Console.WriteLine("GODP:");
        for (int i = 0; i <= 9; i++)
        {
            byte[] output = wmi.Read(0x03, 0x0e, (byte)i);
            Console.WriteLine("  ODP{0}=0x{1:X2} (status=0x{2:X2})", i, output[1], output[0]);
        }
    }

    private static string ToHex(byte[] value, int count)
    {
        var result = new StringBuilder(count * 2);
        for (int i = 0; i < count; i++)
            result.Append(value[i].ToString("X2"));
        return result.ToString();
    }
}

internal sealed class HonorWmi : IDisposable
{
    private readonly IntPtr _library;
    private readonly IntPtr _instance;
    private readonly BiosWmiInit _isInitialized;
    private readonly BiosWmiUninit _uninit;
    private readonly BiosWmiGetOutput _getOutput;
    private bool _disposed;

    public HonorWmi(string pcManagerDir)
    {
        string utilPath = Path.Combine(pcManagerDir, "Util.dll");
        if (!File.Exists(utilPath))
            throw new FileNotFoundException("HONOR PC Manager Util.dll was not found", utilPath);
        if (!SetDllDirectory(pcManagerDir))
            throw new InvalidOperationException("SetDllDirectory failed: " + Marshal.GetLastWin32Error());

        _library = LoadLibrary(utilPath);
        if (_library == IntPtr.Zero)
            throw new InvalidOperationException("LoadLibrary failed: " + Marshal.GetLastWin32Error());
        var instance = GetExport<BiosWmiInstance>("?Instance@BiosWmi@@SAAEAV1@XZ");
        var init = GetExport<BiosWmiInit>("?Init@BiosWmi@@QEAA_NXZ");
        _isInitialized = GetExport<BiosWmiInit>("?IsInitialized@BiosWmi@@QEAA_NXZ");
        _uninit = GetExport<BiosWmiUninit>("?UnInit@BiosWmi@@QEAAXXZ");
        _getOutput = GetExport<BiosWmiGetOutput>("?GetOutPutUIntEx@BiosWmi@@QEAA_NPEAEI0I@Z");
        _instance = instance();
        if (_instance == IntPtr.Zero)
            throw new InvalidOperationException("BiosWmi::Instance returned null");
        if (!_isInitialized(_instance) && !init(_instance))
            throw new InvalidOperationException(string.Format("BiosWmi initialization failed: HRESULT=0x{0:X8}", Marshal.ReadInt32(_instance)));
    }

    public byte[] Read(byte mfid, byte sfid, byte argument)
    {
        if (_disposed)
            throw new ObjectDisposedException("HonorWmi");
        byte[] input = new byte[64];
        byte[] output = new byte[256];
        input[0] = mfid;
        input[1] = sfid;
        input[2] = argument;
        GCHandle inputHandle = GCHandle.Alloc(input, GCHandleType.Pinned);
        GCHandle outputHandle = GCHandle.Alloc(output, GCHandleType.Pinned);
        try
        {
            if (!_getOutput(_instance, inputHandle.AddrOfPinnedObject(), (uint)input.Length,
                    outputHandle.AddrOfPinnedObject(), (uint)output.Length))
                throw new InvalidOperationException(string.Format(
                    "OemWMIfun failed for {0:X2}/{1:X2}: HRESULT=0x{2:X8}, initialized={3}",
                    mfid,
                    sfid,
                    Marshal.ReadInt32(_instance),
                    _isInitialized(_instance)));
        }
        finally
        {
            outputHandle.Free();
            inputHandle.Free();
        }
        return output;
    }

    public void Dispose()
    {
        if (_disposed)
            return;
        _uninit(_instance);
        FreeLibrary(_library);
        SetDllDirectory(null);
        _disposed = true;
    }

    private T GetExport<T>(string name) where T : class
    {
        IntPtr address = GetProcAddress(_library, name);
        if (address == IntPtr.Zero)
            throw new MissingMethodException("Util.dll export not found: " + name);
        return (T)(object)Marshal.GetDelegateForFunctionPointer(address, typeof(T));
    }

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate IntPtr BiosWmiInstance();

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    private delegate bool BiosWmiInit(IntPtr instance);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate void BiosWmiUninit(IntPtr instance);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    private delegate bool BiosWmiGetOutput(IntPtr instance, IntPtr input, uint inputSize, IntPtr output, uint outputSize);

    [DllImport("kernel32.dll", EntryPoint = "SetDllDirectoryW", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetDllDirectory(string path);

    [DllImport("kernel32.dll", EntryPoint = "LoadLibraryW", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr LoadLibrary(string path);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Ansi)]
    private static extern IntPtr GetProcAddress(IntPtr module, string name);

    [DllImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool FreeLibrary(IntPtr module);
}
