using System;
using System.IO;
using System.Text;
using System.Linq;
using System.Diagnostics;
using System.Drawing;
using System.Windows.Forms;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Web.Script.Serialization;
using System.Threading.Tasks;
using Microsoft.Win32;

class BackpackLab : Form {
    static readonly string Here = AppDomain.CurrentDomain.BaseDirectory;
    static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
    TextBox game = new TextBox(), destination = new TextBox();
    Label status = new Label();
    Button install = new Button(), launch = new Button(), shortcut = new Button();
    bool busy;
    public BackpackLab() {
        Text = "背包实验室 · Backpack Lab"; ClientSize = new Size(620, 390);
        StartPosition = FormStartPosition.CenterScreen; FormBorderStyle = FormBorderStyle.FixedDialog; MaximizeBox = false;
        Font = new Font("Microsoft YaHei UI", 10); BackColor = Color.FromArgb(20, 31, 48); ForeColor = Color.White;
        AddLabel("背包实验室", 24, 22, 550, 38).Font = new Font(Font.FontFamily, 22, FontStyle.Bold);
        AddLabel("本地战斗模拟 · 空格重算 · 最佳摆盘对比",24,70,560,28);
        AddLabel("游戏目录",24,112,120,24); game.SetBounds(24,140,486,30); Controls.Add(game);
        var browse = MakeButton("选择…",520,138,76,32); browse.Click += (s,e)=>Choose(game);
        AddLabel("Mod 安装目录",24,183,150,24); destination.SetBounds(24,211,486,30); Controls.Add(destination);
        var destBrowse = MakeButton("选择…",520,209,76,32); destBrowse.Click += (s,e)=>Choose(destination);
        install=MakeButton("安装 / 更新",24,264,150,42); install.Click += async(s,e)=>await Install();
        launch=MakeButton("启动游戏",188,264,150,42); launch.Click += async(s,e)=>await Launch();
        shortcut=MakeButton("桌面快捷方式",352,264,176,42); shortcut.Click += (s,e)=>CreateShortcut();
        status.SetBounds(24,322,568,56); status.ForeColor=Color.FromArgb(174,194,216); Controls.Add(status);
        destination.Text = File.Exists(Path.Combine(Here,"installed-source.json")) ? Here.TrimEnd('\\') : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"BackpackLab");
        string saved=Path.Combine(Here,"launcher-settings.json");
        if(File.Exists(saved)) { var settings=Read(saved); destination.Text=(string)settings["destination"]; }
        string manifest=Path.Combine(RuntimePath(),"installed-source.json");
        game.Text=File.Exists(manifest) ? (string)Read(manifest)["game_directory"] : DetectGame();
        status.Text="首次安装在本机生成资源；原版游戏文件保持不变。";
        FormClosing+=(s,e)=>{if(busy){e.Cancel=true;status.Text="正在安装或校验，请等待完成。";}};
    }
    Label AddLabel(string text,int x,int y,int w,int h){var l=new Label{Text=text};l.SetBounds(x,y,w,h);Controls.Add(l);return l;}
    Button MakeButton(string text,int x,int y,int w,int h){var b=new Button{Text=text,BackColor=Color.FromArgb(48,82,119),ForeColor=Color.White,FlatStyle=FlatStyle.Flat};b.SetBounds(x,y,w,h);Controls.Add(b);return b;}
    void Choose(TextBox box){using(var dialog=new FolderBrowserDialog()){dialog.SelectedPath=box.Text;if(dialog.ShowDialog()==DialogResult.OK)box.Text=dialog.SelectedPath;}}
    void SetBusy(bool value){busy=value;install.Enabled=launch.Enabled=shortcut.Enabled=!value;game.Enabled=destination.Enabled=!value;}
    string RuntimePath(){return File.Exists(Path.Combine(destination.Text,"installed-source.json"))? destination.Text:Path.Combine(destination.Text,"runtime");}
    static Dictionary<string,object> Read(string path){return Json.Deserialize<Dictionary<string,object>>(File.ReadAllText(path,Encoding.UTF8));}
    static string Hash(string path){using(var stream=File.OpenRead(path))using(var sha=SHA256.Create())return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-","").ToLowerInvariant();}
    static void Verify(string runtime){
        var m=Read(Path.Combine(runtime,"installed-source.json")); string g=(string)m["game_directory"];
        foreach(var set in new[]{"hashes","worker_hashes"})foreach(var kv in (Dictionary<string,object>)m[set]){
            string p=Path.Combine(set=="hashes"?g:Path.Combine(runtime,"worker"),kv.Key);
            if(!File.Exists(p)||Hash(p)!=(string)kv.Value)throw new Exception("游戏版本或文件校验不匹配，请重新安装 / 更新。\n"+kv.Key);
        }
        if(Hash(Path.Combine(runtime,"BackpackLab.pck"))!=(string)m["plugin_sha256"])throw new Exception("Mod 文件校验失败，请重新安装。");
    }
    static void StartGame(string runtime){
        Verify(runtime);
        if(Process.GetProcessesByName("BackpackBattles").Length>0)throw new Exception("请先正常退出正在运行的背包乱斗。");
        var m=Read(Path.Combine(runtime,"installed-source.json"));string g=(string)m["game_directory"];
        var p=new ProcessStartInfo(Path.Combine(g,"BackpackBattles.exe"),"--main-pack "+Quote(Path.Combine(runtime,"BackpackLab.pck"))+" "+Quote("--lab-worker="+Path.Combine(runtime,"worker","BackpackLabWorker.exe"))){UseShellExecute=false,WorkingDirectory=g};
        p.EnvironmentVariables["SteamAppId"]="2427700";Process.Start(p);
    }
    async Task Launch(){SetBusy(true);status.Text="正在校验本机游戏与 Mod…";try{string runtime=RuntimePath();await Task.Run(()=>StartGame(runtime));status.Text="游戏已启动。";}catch(Exception e){status.Text=e.Message;}finally{SetBusy(false);}}
    async Task Install(){
        string backend=Path.Combine(Here,"backend","BackpackLabBuild.exe");
        if(!File.Exists(backend)){status.Text="更新时请运行完整下载包中的 BackpackLab.exe。";return;}
        SetBusy(true);status.Text="正在准备本机安装…";
        try{
            string args="--game "+Quote(game.Text)+" --destination "+Quote(destination.Text)+" --source "+Quote(Path.Combine(Here,"source"))+" --gdre "+Quote(Path.Combine(Here,"tools","gdre_tools.exe"))+" --launcher "+Quote(Path.Combine(Here,"BackpackLab.exe"));
            var p=new Process{StartInfo=new ProcessStartInfo(backend,args){UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true,StandardOutputEncoding=Encoding.UTF8,StandardErrorEncoding=Encoding.UTF8}};
            p.OutputDataReceived+=(s,e)=>{if(e.Data!=null)BeginInvoke((Action)(()=>status.Text=e.Data));};
            var errors=new StringBuilder();p.ErrorDataReceived+=(s,e)=>{if(e.Data!=null)lock(errors)errors.AppendLine(e.Data);};
            p.Start();p.BeginOutputReadLine();p.BeginErrorReadLine();await Task.Run(()=>p.WaitForExit());
            if(p.ExitCode!=0)throw new Exception("安装未完成。请查看安装目录内 install.log；原有版本仍保留。");
            status.Text="安装完成，可以启动游戏或创建桌面快捷方式。";
        }catch(Exception e){status.Text=e.Message;}finally{SetBusy(false);}
    }
    void CreateShortcut(){try{
        string exe=File.Exists(Path.Combine(destination.Text,"BackpackLab.exe"))?Path.Combine(destination.Text,"BackpackLab.exe"):Path.Combine(Here,"BackpackLab.exe");
        Type t=Type.GetTypeFromProgID("WScript.Shell");dynamic shell=Activator.CreateInstance(t);
        dynamic link=shell.CreateShortcut(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory),"背包实验室.lnk"));link.TargetPath=exe;link.WorkingDirectory=Path.GetDirectoryName(exe);link.Description="背包实验室 Mod";link.Save();status.Text="桌面快捷方式已创建。";
    }catch(Exception e){status.Text=e.Message;}}
    static string Quote(string value){if(value.Contains("\"")||value.Contains("\n"))throw new Exception("目录包含无效字符。");return "\""+value.TrimEnd('\\')+"\"";}
    static string DetectGame(){
        string steam=(string)Registry.GetValue(@"HKEY_CURRENT_USER\Software\Valve\Steam","SteamPath","");
        var roots=new List<string>();if(!String.IsNullOrEmpty(steam))roots.Add(steam);
        string libraries=Path.Combine(steam??"","steamapps","libraryfolders.vdf");
        if(File.Exists(libraries))foreach(System.Text.RegularExpressions.Match m in System.Text.RegularExpressions.Regex.Matches(File.ReadAllText(libraries),"\"path\"\\s*\"([^\"]+)\""))roots.Add(m.Groups[1].Value.Replace("\\\\","\\"));
        return roots.Select(r=>Path.Combine(r,"steamapps","common","Backpack Battles")).FirstOrDefault(r=>File.Exists(Path.Combine(r,"BackpackBattles.exe")))??"";
    }
    [STAThread] static int Main(string[] args){try{
        if(args.Length==2 && args[0]=="--verify"){Verify(args[1]);return 0;}
        if(args.Length==2 && args[0]=="--launch"){StartGame(args[1]);return 0;}
        Application.EnableVisualStyles();Application.Run(new BackpackLab());return 0;
    }catch(Exception e){if(args.Length==0)MessageBox.Show(e.Message,"背包实验室");return 1;}}
}
