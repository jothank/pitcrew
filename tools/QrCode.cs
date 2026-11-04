// Minimal QR Code encoder (ISO/IEC 18004) for tools\Build-PixQr.ps1: byte mode, error correction
// level M, versions 1 to 10 (up to 213 bytes). Written for PitCrew; the steps follow the order of
// the public specification and of Project Nayuki's reference description (encode, Reed-Solomon,
// interleave, place, mask, format and version bits).
using System;
using System.Collections.Generic;

namespace PitCrew
{
    public sealed class QrCode
    {
        // Level M, versions 1..10: error correction codewords per block, and number of blocks
        static readonly int[] EccPerBlock = { 0, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26 };
        static readonly int[] BlockCount = { 0, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5 };
        static readonly int[][] AlignmentPositions = {
            null, new int[0], new[] { 6, 18 }, new[] { 6, 22 }, new[] { 6, 26 }, new[] { 6, 30 }, new[] { 6, 34 },
            new[] { 6, 22, 38 }, new[] { 6, 24, 42 }, new[] { 6, 26, 46 }, new[] { 6, 28, 50 } };

        public int Version { get; private set; }
        public int Size { get; private set; }
        public int Mask { get; private set; }
        bool[,] modules;    // [y, x], true = dark
        bool[,] isFunction;

        public bool IsDark(int x, int y) { return modules[y, x]; }

        public static QrCode Encode(byte[] data)
        {
            int version = 1;
            while (version <= 10 && 4 + (version <= 9 ? 8 : 16) + data.Length * 8 > DataCodewords(version) * 8) version++;
            if (version > 10) throw new ArgumentException("Too long for versions 1-10 at level M");

            var bits = new List<bool>();
            Append(bits, 4, 4);                                  // byte mode
            Append(bits, data.Length, version <= 9 ? 8 : 16);    // character count
            foreach (byte b in data) Append(bits, b, 8);
            int capacity = DataCodewords(version) * 8;
            Append(bits, 0, Math.Min(4, capacity - bits.Count)); // terminator
            Append(bits, 0, (8 - bits.Count % 8) % 8);           // to a byte boundary
            for (int pad = 0xEC; bits.Count < capacity; pad ^= 0xEC ^ 0x11) Append(bits, pad, 8);
            var codewords = new byte[bits.Count / 8];
            for (int i = 0; i < bits.Count; i++) if (bits[i]) codewords[i >> 3] |= (byte)(0x80 >> (i & 7));

            var qr = new QrCode(version);
            qr.Build(AddEccAndInterleave(codewords, version));
            return qr;
        }

        QrCode(int version)
        {
            Version = version;
            Size = version * 4 + 17;
            modules = new bool[Size, Size];
            isFunction = new bool[Size, Size];
        }

        static void Append(List<bool> bits, int value, int count)
        {
            for (int i = count - 1; i >= 0; i--) bits.Add(((value >> i) & 1) != 0);
        }

        static int RawModules(int version)
        {
            int result = (16 * version + 128) * version + 64;
            if (version >= 2)
            {
                int align = version / 7 + 2;
                result -= (25 * align - 10) * align - 55;
                if (version >= 7) result -= 36;
            }
            return result;
        }

        public static int DataCodewords(int version)
        {
            return RawModules(version) / 8 - EccPerBlock[version] * BlockCount[version];
        }

        // --- Reed-Solomon over GF(256) with polynomial 0x11D ---

        static int Multiply(int x, int y)
        {
            int z = 0;
            for (int i = 7; i >= 0; i--)
            {
                z = (z << 1) ^ ((z >> 7) * 0x11D);
                z ^= ((y >> i) & 1) * x;
            }
            return z;
        }

        static byte[] Divisor(int degree)
        {
            var result = new byte[degree];
            result[degree - 1] = 1;
            int root = 1;
            for (int i = 0; i < degree; i++)
            {
                for (int j = 0; j < degree; j++)
                {
                    result[j] = (byte)Multiply(result[j], root);
                    if (j + 1 < degree) result[j] ^= result[j + 1];
                }
                root = Multiply(root, 0x02);
            }
            return result;
        }

        public static byte[] ReedSolomon(byte[] data, int eccLength)
        {
            byte[] divisor = Divisor(eccLength);
            var result = new byte[eccLength];
            foreach (byte b in data)
            {
                int factor = b ^ result[0];
                Array.Copy(result, 1, result, 0, eccLength - 1);
                result[eccLength - 1] = 0;
                for (int i = 0; i < eccLength; i++) result[i] ^= (byte)Multiply(divisor[i], factor);
            }
            return result;
        }

        static byte[] AddEccAndInterleave(byte[] data, int version)
        {
            int blocks = BlockCount[version], eccLength = EccPerBlock[version];
            int raw = RawModules(version) / 8;
            int shortBlocks = blocks - raw % blocks;
            int shortLength = raw / blocks;    // data + ecc of a short block
            var all = new List<byte[]>();
            for (int i = 0, k = 0; i < blocks; i++)
            {
                int dataLength = shortLength - eccLength + (i < shortBlocks ? 0 : 1);
                var block = new byte[shortLength + 1];
                Array.Copy(data, k, block, 0, dataLength);
                k += dataLength;
                byte[] ecc = ReedSolomon(SubArray(data, k - dataLength, dataLength), eccLength);
                // Short blocks keep an unused slot before their ecc so every block lines up
                Array.Copy(ecc, 0, block, shortLength + 1 - eccLength, eccLength);
                all.Add(block);
            }
            var result = new List<byte>();
            for (int i = 0; i <= shortLength; i++)
                for (int j = 0; j < blocks; j++)
                    if (i != shortLength - eccLength || j >= shortBlocks) result.Add(all[j][i]);
            return result.ToArray();
        }

        static byte[] SubArray(byte[] source, int start, int length)
        {
            var result = new byte[length];
            Array.Copy(source, start, result, 0, length);
            return result;
        }

        // --- Matrix ---

        void Set(int x, int y, bool dark)
        {
            modules[y, x] = dark;
            isFunction[y, x] = true;
        }

        void Build(byte[] codewords)
        {
            for (int i = 0; i < Size; i++) { Set(6, i, i % 2 == 0); Set(i, 6, i % 2 == 0); }
            Finder(3, 3); Finder(Size - 4, 3); Finder(3, Size - 4);
            int[] positions = AlignmentPositions[Version];
            int n = positions.Length;
            for (int i = 0; i < n; i++)
                for (int j = 0; j < n; j++)
                    if (!(i == 0 && j == 0) && !(i == 0 && j == n - 1) && !(i == n - 1 && j == 0)) Alignment(positions[i], positions[j]);
            DrawFormat(0);
            DrawVersion();
            Place(codewords);

            int best = 0, bestPenalty = int.MaxValue;
            for (int m = 0; m < 8; m++)
            {
                ApplyMask(m);
                DrawFormat(m);
                int penalty = Penalty();
                if (penalty < bestPenalty) { best = m; bestPenalty = penalty; }
                ApplyMask(m);   // masking twice restores the data
            }
            Mask = best;
            ApplyMask(best);
            DrawFormat(best);
        }

        void Finder(int cx, int cy)
        {
            for (int dy = -4; dy <= 4; dy++)
                for (int dx = -4; dx <= 4; dx++)
                {
                    int d = Math.Max(Math.Abs(dx), Math.Abs(dy)), x = cx + dx, y = cy + dy;
                    if (x >= 0 && x < Size && y >= 0 && y < Size) Set(x, y, d != 2 && d != 4);
                }
        }

        void Alignment(int cx, int cy)
        {
            for (int dy = -2; dy <= 2; dy++)
                for (int dx = -2; dx <= 2; dx++) Set(cx + dx, cy + dy, Math.Max(Math.Abs(dx), Math.Abs(dy)) != 1);
        }

        static bool Bit(int value, int i) { return ((value >> i) & 1) != 0; }

        public static int FormatBits(int mask)
        {
            int data = (0 << 3) | mask;    // level M is 00
            int rem = data;
            for (int i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >> 9) * 0x537);
            return ((data << 10) | rem) ^ 0x5412;
        }

        void DrawFormat(int mask)
        {
            int bits = FormatBits(mask);
            for (int i = 0; i <= 5; i++) Set(8, i, Bit(bits, i));
            Set(8, 7, Bit(bits, 6));
            Set(8, 8, Bit(bits, 7));
            Set(7, 8, Bit(bits, 8));
            for (int i = 9; i < 15; i++) Set(14 - i, 8, Bit(bits, i));
            for (int i = 0; i < 8; i++) Set(Size - 1 - i, 8, Bit(bits, i));
            for (int i = 8; i < 15; i++) Set(8, Size - 15 + i, Bit(bits, i));
            Set(8, Size - 8, true);    // the dark module
        }

        void DrawVersion()
        {
            if (Version < 7) return;
            int rem = Version;
            for (int i = 0; i < 12; i++) rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
            int bits = (Version << 12) | rem;
            for (int i = 0; i < 18; i++)
            {
                bool b = Bit(bits, i);
                int a = Size - 11 + i % 3, c = i / 3;
                Set(a, c, b);
                Set(c, a, b);
            }
        }

        void Place(byte[] codewords)
        {
            int index = 0, total = codewords.Length * 8;
            for (int right = Size - 1; right >= 1; right -= 2)
            {
                if (right == 6) right = 5;    // the vertical timing column is skipped
                bool upward = ((right + 1) & 2) == 0;
                for (int vert = 0; vert < Size; vert++)
                    for (int j = 0; j < 2; j++)
                    {
                        int x = right - j, y = upward ? Size - 1 - vert : vert;
                        if (!isFunction[y, x] && index < total)
                        {
                            modules[y, x] = ((codewords[index >> 3] >> (7 - (index & 7))) & 1) != 0;
                            index++;
                        }
                    }
            }
        }

        void ApplyMask(int mask)
        {
            for (int y = 0; y < Size; y++)
                for (int x = 0; x < Size; x++)
                {
                    if (isFunction[y, x]) continue;
                    bool invert;
                    switch (mask)
                    {
                        case 0: invert = (x + y) % 2 == 0; break;
                        case 1: invert = y % 2 == 0; break;
                        case 2: invert = x % 3 == 0; break;
                        case 3: invert = (x + y) % 3 == 0; break;
                        case 4: invert = (x / 3 + y / 2) % 2 == 0; break;
                        case 5: invert = x * y % 2 + x * y % 3 == 0; break;
                        case 6: invert = (x * y % 2 + x * y % 3) % 2 == 0; break;
                        default: invert = ((x + y) % 2 + x * y % 3) % 2 == 0; break;
                    }
                    if (invert) modules[y, x] = !modules[y, x];
                }
        }

        static readonly bool[] FinderLikeA = { true, false, true, true, true, false, true, false, false, false, false };
        static readonly bool[] FinderLikeB = { false, false, false, false, true, false, true, true, true, false, true };

        int Penalty()
        {
            int result = 0;
            for (int pass = 0; pass < 2; pass++)    // rows, then columns
            {
                for (int a = 0; a < Size; a++)
                {
                    int run = 1;
                    for (int b = 1; b < Size; b++)
                    {
                        bool cur = pass == 0 ? modules[a, b] : modules[b, a];
                        bool prev = pass == 0 ? modules[a, b - 1] : modules[b - 1, a];
                        if (cur == prev) { run++; if (run == 5) result += 3; else if (run > 5) result++; }
                        else run = 1;
                    }
                    for (int b = 0; b + 11 <= Size; b++)
                    {
                        bool matchA = true, matchB = true;
                        for (int k = 0; k < 11; k++)
                        {
                            bool cur = pass == 0 ? modules[a, b + k] : modules[b + k, a];
                            if (cur != FinderLikeA[k]) matchA = false;
                            if (cur != FinderLikeB[k]) matchB = false;
                        }
                        if (matchA) result += 40;
                        if (matchB) result += 40;
                    }
                }
            }
            for (int y = 0; y < Size - 1; y++)
                for (int x = 0; x < Size - 1; x++)
                {
                    bool c = modules[y, x];
                    if (c == modules[y, x + 1] && c == modules[y + 1, x] && c == modules[y + 1, x + 1]) result += 3;
                }
            int dark = 0;
            for (int y = 0; y < Size; y++) for (int x = 0; x < Size; x++) if (modules[y, x]) dark++;
            int total = Size * Size;
            int k2 = (Math.Abs(dark * 20 - total * 10) + total - 1) / total - 1;
            result += Math.Max(0, k2) * 10;
            return result;
        }
    }
}
