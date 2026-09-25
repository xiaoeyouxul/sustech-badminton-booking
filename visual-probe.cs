using System;
using System.Drawing;
using System.Windows.Forms;
using System.Runtime.InteropServices;
using System.Collections.Generic;

// Small, local screenshot checks. No OCR, browser access or network requests.
public static class VisualProbe {
    [StructLayout(LayoutKind.Sequential)] struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out Rect r);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    static readonly Dictionary<string, Bitmap> templates = new Dictionary<string, Bitmap>();
    static Rectangle Bounds(IntPtr h) {
        Rect r;
        if (GetForegroundWindow() != h || !GetWindowRect(h, out r))
            throw new InvalidOperationException("视觉检查时目标窗口失去前台焦点");
        return Rectangle.Intersect(Rectangle.FromLTRB(r.Left,r.Top,r.Right,r.Bottom), Screen.FromHandle(h).WorkingArea);
    }
    public static int[] Sample(IntPtr h, double[] points) {
        Rectangle r = Bounds(h);
        int minX=r.Width, minY=r.Height, maxX=0, maxY=0;
        int[] xs=new int[points.Length/2], ys=new int[xs.Length];
        for(int i=0;i<xs.Length;i++) {
            xs[i]=(int)Math.Round(points[i*2]*r.Width); ys[i]=(int)Math.Round(points[i*2+1]*r.Height);
            minX=Math.Min(minX,xs[i]); maxX=Math.Max(maxX,xs[i]);
            minY=Math.Min(minY,ys[i]); maxY=Math.Max(maxY,ys[i]);
        }
        using(Bitmap b=new Bitmap(maxX-minX+1,maxY-minY+1)) {
            using(Graphics g=Graphics.FromImage(b)) g.CopyFromScreen(r.Left+minX,r.Top+minY,0,0,b.Size);
            int[] result=new int[xs.Length];
            for(int i=0;i<xs.Length;i++) result[i]=b.GetPixel(xs[i]-minX,ys[i]-minY).ToArgb();
            return result;
        }
    }
    public static bool Match(IntPtr h, string path, int x, int y) {
        Rectangle r=Bounds(h);
        Bitmap template;
        if(!templates.TryGetValue(path,out template)) { template=new Bitmap(path); templates.Add(path,template); }
        double sx=r.Width/2559.0, sy=r.Height/1530.0;
        int w=(int)Math.Round(template.Width*sx), height=(int)Math.Round(template.Height*sy);
        const int pad=8;
        using(Bitmap target=new Bitmap(w,height))
        using(Bitmap actual=new Bitmap(w+pad*2,height+pad*2)) {
            using(Graphics g=Graphics.FromImage(target)) g.DrawImage(template,0,0,w,height);
            using(Graphics g=Graphics.FromImage(actual))
                g.CopyFromScreen(r.Left+(int)Math.Round(x*sx)-pad,r.Top+(int)Math.Round(y*sy)-pad,0,0,actual.Size);
            return Matches(actual,target,pad);
        }
    }
    // Exposed for offline regression checks with supplied screenshots.
    public static bool Matches(Bitmap actual, Bitmap target, int pad) {
        for(int dy=0;dy<=pad*2;dy+=2) for(int dx=0;dx<=pad*2;dx+=2) {
            long error=0; int count=0;
            for(int y=1;y<target.Height;y+=3) for(int x=1;x<target.Width;x+=3) {
                Color a=actual.GetPixel(x+dx,y+dy), b=target.GetPixel(x,y);
                error+=Math.Abs(a.R-b.R)+Math.Abs(a.G-b.G)+Math.Abs(a.B-b.B); count+=3;
            }
            if(count>0 && error/(double)count<18) return true;
        }
        return false;
    }
}
