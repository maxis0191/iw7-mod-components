using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace IW7.VoiceAgent
{
    // Enumeration/property reads only. No audio-client activation, capture,
    // endpoint-volume API, policy API, property write or default-device change.
    public static class CoreAudioInventory
    {
        [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
        private class DeviceEnumerator { }
        [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IEnumerator
        {
            void EnumAudioEndpoints(int flow, uint stateMask, out ICollection devices);
            void GetDefaultAudioEndpoint(int flow, int role, out IDevice device);
            void GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IDevice device);
            void RegisterEndpointNotificationCallback(IntPtr callback);
            void UnregisterEndpointNotificationCallback(IntPtr callback);
        }
        [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface ICollection
        {
            void GetCount(out uint count);
            void Item(uint index, out IDevice device);
        }
        [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IDevice
        {
            void Activate(ref Guid iid, uint context, IntPtr parameters, out IntPtr instance);
            void OpenPropertyStore(uint access, out IProperties properties);
            void GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
            void GetState(out uint state);
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct Key { public Guid format; public uint id; }
        [StructLayout(LayoutKind.Explicit, Size = 24)]
        private struct Variant
        {
            [FieldOffset(0)] public ushort type;
            [FieldOffset(8)] public IntPtr pointer;
        }
        [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IProperties
        {
            void GetCount(out uint count);
            void GetAt(uint index, out Key key);
            void GetValue(ref Key key, out Variant value);
            void SetValue(ref Key key, ref Variant value);
            void Commit();
        }
        [DllImport("ole32.dll")] private static extern int PropVariantClear(ref Variant value);
        private static void Release(object value) { if (value != null && Marshal.IsComObject(value)) Marshal.FinalReleaseComObject(value); }
        public sealed class Endpoint
        {
            public string Id { get; set; }
            public string EndpointGuid { get; set; }
            public string Flow { get; set; }
            public string Name { get; set; }
            public uint State { get; set; }
            public string StateName { get; set; }
            public string[] DefaultRoles { get; set; }
        }
        public sealed class CaptureDevice
        {
            public string Guid { get; set; }
            public string Description { get; set; }
            public string Module { get; set; }
            public bool DefaultAlias { get; set; }
        }
        private delegate bool CaptureEnumCallback(IntPtr guid, [MarshalAs(UnmanagedType.LPWStr)] string description,
            [MarshalAs(UnmanagedType.LPWStr)] string module, IntPtr context);
        [DllImport("dsound.dll", CharSet = CharSet.Unicode)]
        private static extern int DirectSoundCaptureEnumerateW(CaptureEnumCallback callback, IntPtr context);
        public static CaptureDevice[] ReadDirectSoundCapture()
        {
            var devices = new List<CaptureDevice>();
            CaptureEnumCallback callback = (guid, description, module, context) =>
            {
                devices.Add(new CaptureDevice { Guid = guid == IntPtr.Zero ? null : Marshal.PtrToStructure<Guid>(guid).ToString(),
                    DefaultAlias = guid == IntPtr.Zero, Description = description, Module = module });
                return true;
            };
            Marshal.ThrowExceptionForHR(DirectSoundCaptureEnumerateW(callback, IntPtr.Zero));
            GC.KeepAlive(callback);
            return devices.ToArray();
        }
        public static Endpoint[] Read()
        {
            var enumerator = (IEnumerator)new DeviceEnumerator();
            var result = new List<Endpoint>();
            try
            {
                for (int flow = 0; flow < 2; ++flow)
                {
                    var defaults = new Dictionary<string, List<string>>();
                    for (int role = 0; role < 3; ++role)
                    {
                        IDevice device = null;
                        try
                        {
                            enumerator.GetDefaultAudioEndpoint(flow, role, out device);
                            string id; device.GetId(out id);
                            if (!defaults.ContainsKey(id)) defaults[id] = new List<string>();
                            defaults[id].Add(new[] { "console", "multimedia", "communications" }[role]);
                        }
                        catch (COMException error)
                        {
                            // No default endpoint is a legitimate inventory result.
                            if (error.HResult != unchecked((int)0x80070490)) throw;
                        }
                        finally { Release(device); }
                    }
                    ICollection collection = null;
                    try
                    {
                        enumerator.EnumAudioEndpoints(flow, 15, out collection);
                        uint count; collection.GetCount(out count);
                        for (uint index = 0; index < count; ++index)
                        {
                            IDevice device = null; IProperties properties = null;
                            try
                            {
                                collection.Item(index, out device);
                                string id; uint state; device.GetId(out id); device.GetState(out state);
                                device.OpenPropertyStore(0, out properties);
                                var key = new Key { format = new Guid("A45C254E-DF1C-4EFD-8020-67D146A850E0"), id = 14 };
                                Variant value; properties.GetValue(ref key, out value);
                                string name;
                                try { name = value.type == 31 ? Marshal.PtrToStringUni(value.pointer) : "unavailable"; }
                                finally { PropVariantClear(ref value); }
                                // SDK mmdeviceapi.h PKEY_AudioEndpoint_GUID. This
                                // maps the endpoint to DirectSound enumeration; it is not a selector.
                                var guidKey = new Key { format = new Guid("1DA5D803-D492-4EDD-8C23-E0C0FFEE7F0E"), id = 4 };
                                Variant guidValue; properties.GetValue(ref guidKey, out guidValue);
                                string endpointGuid;
                                try { endpointGuid = guidValue.type == 31 ? Marshal.PtrToStringUni(guidValue.pointer) : null; }
                                finally { PropVariantClear(ref guidValue); }
                                result.Add(new Endpoint { Id = id, EndpointGuid = endpointGuid, Name = name, State = state,
                                    Flow = flow == 0 ? "render" : "capture",
                                    StateName = state == 1 ? "active" : state == 2 ? "disabled" : state == 4 ? "not_present" : state == 8 ? "unplugged" : "unknown",
                                    DefaultRoles = defaults.ContainsKey(id) ? defaults[id].ToArray() : new string[0] });
                            }
                            finally { Release(properties); Release(device); }
                        }
                    }
                    finally { Release(collection); }
                }
                return result.ToArray();
            }
            finally { Release(enumerator); }
        }
    }
}
