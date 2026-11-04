// PitCrew.exe: lets anyone start PitCrew with a double click.
//
// It holds no PitCrew logic and no embedded script. It only:
//   1. checks that the zip was extracted (PitCrew.ps1 and src\ must be next to it);
//   2. asks Windows for administrator rights, so the UAC prompt names PitCrew and shows its icon;
//      if the answer is No, PitCrew still opens, read-only;
//   3. starts PitCrew.ps1 with the 64-bit Windows PowerShell 5.1 that comes with Windows.
//
// tools\Build-Release.ps1 compiles it with the C# compiler that ships with Windows (.NET Framework
// 4), so anyone can rebuild it from this file. That compiler stamps the build time into the exe, so
// two builds never match byte for byte: judge it by reading this file.
//
// "--dry-run" walks through exactly the same steps but prints each program it would start instead
// of starting it; with it, "--simulate-refusal" answers No to the UAC prompt and
// "--simulate-not-admin" acts as if run without administrator rights. tests\Launcher-Tests.ps1
// uses them.
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;

[assembly: AssemblyTitle("PitCrew")]
[assembly: AssemblyProduct("PitCrew")]
[assembly: AssemblyDescription("Tune-up for Windows. Every change can be undone.")]
[assembly: AssemblyCompany("Jonathan Costa")]
[assembly: AssemblyCopyright("Copyright (c) 2026 Jonathan Costa. MIT License.")]

namespace PitCrew
{
    static class Launcher
    {
        const int ErrorCancelled = 1223;    // the user answered No to the UAC prompt
        const int ExitAlreadyShown = 2;     // PitCrew.ps1 already showed its error in a message box
        const uint MessageBoxWarning = 0x30;

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern int MessageBoxW(IntPtr owner, string text, string caption, uint type);

        static TextWriter output;           // set by --dry-run; UTF-8 so localized text survives a redirect
        static bool simulateRefusal;
        static string language;

        [STAThread]
        static int Main(string[] args)
        {
            bool dryRun = false, alreadyAsked = false, noRestorePoint = false, simulateNotAdmin = false;
            for (int i = 0; i < args.Length; i++)
            {
                string a = args[i];
                if (a == "--dry-run") dryRun = true;
                else if (a == "--simulate-refusal") simulateRefusal = true;
                else if (a == "--simulate-not-admin") simulateNotAdmin = true;
                else if (a == "--elevated") alreadyAsked = true;
                else if (string.Equals(a, "-NoRestorePoint", StringComparison.OrdinalIgnoreCase)) noRestorePoint = true;
                else if (string.Equals(a, "-Language", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length) language = args[++i];
            }
            // Only a plain language tag is passed on to PowerShell, never free text (\z: not even a newline)
            if (language != null && !Regex.IsMatch(language, @"^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})?\z")) language = null;
            if (dryRun)
            {
                var writer = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false));
                writer.AutoFlush = true;
                output = writer;
            }

            // The folder comes from this file's location, not the current directory (shortcuts change it)
            string exe = Assembly.GetExecutingAssembly().Location;
            string folder = Path.GetDirectoryName(exe);
            string script = Path.Combine(folder, "PitCrew.ps1");
            if (!File.Exists(script) || !File.Exists(Path.Combine(folder, @"src\Load.ps1")))
                return Fail(Text("extract"));

            // Always the 64-bit PowerShell, by full path: never one found next to this file or on PATH.
            // A 32-bit process on 64-bit Windows sees System32 redirected, so it goes through Sysnative;
            // a 32-bit PowerShell would write machine settings into WOW6432Node.
            string system = Environment.Is64BitOperatingSystem && !Environment.Is64BitProcess
                ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "Sysnative")
                : Environment.SystemDirectory;
            string powershell = Path.Combine(system, @"WindowsPowerShell\v1.0\powershell.exe");
            if (!File.Exists(powershell))
                return Fail(Text("noPowerShell"));

            string extra = (language != null ? " -Language " + language : "") + (noRestorePoint ? " -NoRestorePoint" : "");
            bool admin = new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator);
            // The simulations only ever apply to a dry run
            if (!dryRun) simulateRefusal = simulateNotAdmin = false;
            if (simulateNotAdmin) admin = false;
            if (output != null)
            {
                output.WriteLine("folder=" + folder);
                output.WriteLine("is64=" + Environment.Is64BitProcess);
                output.WriteLine("admin=" + admin);
            }

            // "--elevated" marks the copy started through UAC, so it can never ask in a loop
            if (!admin && !alreadyAsked)
            {
                var self = new ProcessStartInfo(exe, "--elevated" + extra);
                self.UseShellExecute = true;
                self.Verb = "runas";
                self.WorkingDirectory = Environment.SystemDirectory;
                try
                {
                    Start(self);
                    return 0;   // the elevated copy takes over from here
                }
                catch (Win32Exception e)
                {
                    // No: open read-only (PitCrew.ps1 shows a banner). Any other failure is reported first.
                    if (e.NativeErrorCode != ErrorCancelled) Warn(string.Format(Text("elevationFailed"), e.Message));
                }
            }

            // -NoElevate: this launcher already asked for administrator, PitCrew.ps1 must not ask again
            var ps = new ProcessStartInfo(powershell, "-NoProfile -STA -ExecutionPolicy Bypass -File " + Quote(script) + " -NoElevate" + extra);
            ps.UseShellExecute = false;
            ps.CreateNoWindow = true;                           // no console window behind PitCrew
            ps.WorkingDirectory = Environment.SystemDirectory;  // not the download folder
            Process started;
            try
            {
                started = Start(ps);
            }
            catch (Exception e)
            {
                return Fail(Text("startFailed") + "\n\n" + e.Message);
            }

            // A failure before PitCrew's window opens (a Group Policy that blocks scripts, a damaged file)
            // would otherwise vanish with the hidden PowerShell
            if (started != null && started.WaitForExit(15000) && started.ExitCode != 0 && started.ExitCode != ExitAlreadyShown)
                return Fail(string.Format(Text("closedEarly"), started.ExitCode));
            return 0;
        }

        // The only place anything is started. With --dry-run it prints instead.
        static Process Start(ProcessStartInfo info)
        {
            if (output == null) return Process.Start(info);
            output.WriteLine("start=" + Quote(info.FileName) + " " + info.Arguments + " | verb=" + info.Verb +
                " shell=" + info.UseShellExecute + " nowindow=" + info.CreateNoWindow + " dir=" + info.WorkingDirectory);
            if (simulateRefusal && info.Verb == "runas") throw new Win32Exception(ErrorCancelled);
            return null;
        }

        static string Quote(string path)
        {
            // Windows paths can't contain quotes, and these never end with a backslash
            return "\"" + path + "\"";
        }

        static void Warn(string message)
        {
            if (output != null) output.WriteLine("warning=" + message.Replace("\n", " "));
            else MessageBoxW(IntPtr.Zero, message, "PitCrew", MessageBoxWarning);
        }

        static int Fail(string message)
        {
            if (output != null) output.WriteLine("error=" + message.Replace("\n", " "));
            else MessageBoxW(IntPtr.Zero, message, "PitCrew", MessageBoxWarning);
            return 1;
        }

        static readonly string[] Languages = { "en", "pt", "es", "fr", "de", "ru", "tr", "zh" };

        static readonly Dictionary<string, string[]> Messages = new Dictionary<string, string[]>
        {
            { "extract", new[] {
                "PitCrew can't find its files.\n\nIf you opened it from inside the .zip file, first right-click the .zip, choose \"Extract All...\", then open PitCrew.exe in the extracted PitCrew folder.",
                "O PitCrew não encontrou os arquivos dele.\n\nSe você abriu direto de dentro do .zip, primeiro clique com o botão direito no .zip, escolha \"Extrair tudo...\" e depois abra o PitCrew.exe na pasta PitCrew extraída.",
                "PitCrew no encuentra sus archivos.\n\nSi lo abriste desde dentro del archivo .zip, primero haz clic derecho en el .zip, elige \"Extraer todo...\" y luego abre PitCrew.exe en la carpeta PitCrew extraída.",
                "PitCrew ne trouve pas ses fichiers.\n\nSi vous l'avez ouvert depuis le fichier .zip, faites d'abord un clic droit sur le .zip, choisissez « Extraire tout... », puis ouvrez PitCrew.exe dans le dossier PitCrew extrait.",
                "PitCrew findet seine Dateien nicht.\n\nWenn Sie es direkt aus der ZIP-Datei geöffnet haben, klicken Sie zuerst mit der rechten Maustaste auf die ZIP-Datei, wählen Sie „Alle extrahieren...“ und öffnen Sie dann PitCrew.exe im entpackten Ordner PitCrew.",
                "PitCrew не находит свои файлы.\n\nЕсли вы открыли его прямо из ZIP-архива, сначала щёлкните архив правой кнопкой, выберите «Извлечь все...», а затем откройте PitCrew.exe в распакованной папке PitCrew.",
                "PitCrew dosyalarını bulamıyor.\n\n.zip dosyasının içinden açtıysanız, önce .zip dosyasına sağ tıklayıp \"Tümünü ayıkla...\" seçeneğini seçin, ardından çıkarılan PitCrew klasöründeki PitCrew.exe'yi açın.",
                "PitCrew 找不到它的文件。\n\n如果你是直接在 .zip 文件里打开的，请先右键单击 .zip，选择“全部解压缩...”，然后打开解压出的 PitCrew 文件夹中的 PitCrew.exe。" } },
            { "noPowerShell", new[] {
                "Windows PowerShell 5.1 was not found on this PC. PitCrew needs the Windows PowerShell that comes with Windows 10 and 11.",
                "O Windows PowerShell 5.1 não foi encontrado neste PC. O PitCrew precisa do Windows PowerShell que vem com o Windows 10 e 11.",
                "No se encontró Windows PowerShell 5.1 en este PC. PitCrew necesita el Windows PowerShell que viene con Windows 10 y 11.",
                "Windows PowerShell 5.1 est introuvable sur ce PC. PitCrew a besoin du Windows PowerShell fourni avec Windows 10 et 11.",
                "Windows PowerShell 5.1 wurde auf diesem PC nicht gefunden. PitCrew benötigt das Windows PowerShell, das mit Windows 10 und 11 geliefert wird.",
                "На этом ПК не найден Windows PowerShell 5.1. PitCrew нужен Windows PowerShell, который входит в Windows 10 и 11.",
                "Bu bilgisayarda Windows PowerShell 5.1 bulunamadı. PitCrew, Windows 10 ve 11 ile gelen Windows PowerShell'e ihtiyaç duyar.",
                "此电脑上找不到 Windows PowerShell 5.1。PitCrew 需要 Windows 10 和 11 自带的 Windows PowerShell。" } },
            { "startFailed", new[] {
                "PitCrew could not start. You can also open it with PitCrew.bat in the same folder.",
                "O PitCrew não conseguiu abrir. Você também pode abri-lo pelo PitCrew.bat, na mesma pasta.",
                "PitCrew no pudo iniciarse. También puedes abrirlo con PitCrew.bat, en la misma carpeta.",
                "PitCrew n'a pas pu démarrer. Vous pouvez aussi l'ouvrir avec PitCrew.bat, dans le même dossier.",
                "PitCrew konnte nicht starten. Sie können es auch mit PitCrew.bat im selben Ordner öffnen.",
                "Не удалось запустить PitCrew. Его также можно открыть через PitCrew.bat в той же папке.",
                "PitCrew başlatılamadı. Aynı klasördeki PitCrew.bat ile de açabilirsiniz.",
                "PitCrew 无法启动。你也可以用同一文件夹中的 PitCrew.bat 打开它。" } },
            { "elevationFailed", new[] {
                "Windows couldn't start PitCrew as administrator ({0}). It will open read-only.",
                "O Windows não conseguiu abrir o PitCrew como administrador ({0}). Ele vai abrir em modo somente leitura.",
                "Windows no pudo abrir PitCrew como administrador ({0}). Se abrirá en modo de solo lectura.",
                "Windows n'a pas pu ouvrir PitCrew en tant qu'administrateur ({0}). Il va s'ouvrir en lecture seule.",
                "Windows konnte PitCrew nicht als Administrator starten ({0}). Es wird schreibgeschützt geöffnet.",
                "Windows не удалось запустить PitCrew от имени администратора ({0}). Программа откроется только для просмотра.",
                "Windows, PitCrew'u yönetici olarak başlatamadı ({0}). Salt okunur modda açılacak.",
                "Windows 无法以管理员身份启动 PitCrew（{0}）。它将以只读模式打开。" } },
            { "closedEarly", new[] {
                "PitCrew closed with an error (code {0}). To see the message, open PitCrew.bat in the same folder.",
                "O PitCrew fechou com um erro (código {0}). Para ver a mensagem, abra o PitCrew.bat na mesma pasta.",
                "PitCrew se cerró con un error (código {0}). Para ver el mensaje, abre PitCrew.bat en la misma carpeta.",
                "PitCrew s'est fermé sur une erreur (code {0}). Pour voir le message, ouvrez PitCrew.bat dans le même dossier.",
                "PitCrew wurde mit einem Fehler beendet (Code {0}). Um die Meldung zu sehen, öffnen Sie PitCrew.bat im selben Ordner.",
                "PitCrew закрылся с ошибкой (код {0}). Чтобы увидеть сообщение, откройте PitCrew.bat в той же папке.",
                "PitCrew bir hatayla kapandı (kod {0}). Mesajı görmek için aynı klasördeki PitCrew.bat dosyasını açın.",
                "PitCrew 因错误而关闭（代码 {0}）。要查看消息，请打开同一文件夹中的 PitCrew.bat。" } },
        };

        static string Text(string key)
        {
            string tag = (language ?? CultureInfo.CurrentUICulture.Name).ToLowerInvariant();
            int index = 0;
            for (int i = 0; i < Languages.Length; i++)
            {
                if (tag.StartsWith(Languages[i], StringComparison.Ordinal)) { index = i; break; }
            }
            return Messages[key][index];
        }
    }
}
