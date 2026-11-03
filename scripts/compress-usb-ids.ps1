#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InputPath,
    [Parameter(Mandatory)][string]$OutputPath
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not ('Comls.MsZip' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace Comls {
    public static class MsZip {
        [DllImport("cabinet.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateCompressor(uint algorithm, IntPtr allocator, out IntPtr handle);

        [DllImport("cabinet.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool Compress(IntPtr handle, byte[] input, UIntPtr inputSize,
            byte[] output, UIntPtr outputSize, out UIntPtr written);

        [DllImport("cabinet.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseCompressor(IntPtr handle);

        public static byte[] Encode(byte[] input) {
            if (input.Length == 0 || input.Length > 64 * 1024 * 1024)
                throw new ArgumentException("USB database must be between 1 byte and 64 MiB.");
            IntPtr handle;
            if (!CreateCompressor(2, IntPtr.Zero, out handle)) // COMPRESS_ALGORITHM_MSZIP
                throw new Win32Exception(Marshal.GetLastWin32Error());
            try {
                UIntPtr needed;
                bool success = Compress(handle, input, (UIntPtr)input.Length,
                    null, UIntPtr.Zero, out needed);
                int error = Marshal.GetLastWin32Error();
                if (success || error != 122) // ERROR_INSUFFICIENT_BUFFER
                    throw new Win32Exception(success ? 13 : error);
                byte[] output = new byte[checked((int)needed.ToUInt64())];
                if (!Compress(handle, input, (UIntPtr)input.Length,
                    output, (UIntPtr)output.Length, out needed))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                Array.Resize(ref output, checked((int)needed.ToUInt64()));
                return output;
            } finally {
                CloseCompressor(handle);
            }
        }
    }
}
'@
}
$inputBytes = [System.IO.File]::ReadAllBytes($InputPath)
$compressed = [Comls.MsZip]::Encode($inputBytes)
[System.IO.File]::WriteAllBytes($OutputPath, $compressed)
