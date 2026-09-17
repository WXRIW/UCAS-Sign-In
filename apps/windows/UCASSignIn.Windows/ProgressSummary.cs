using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;

namespace UCASSignIn.Windows;

public sealed partial class MainWindow
{
    FrameworkElement SummaryMetric(string label, int count)
    {
        var value = Text("", 27, true);
        value.Language = "zh-CN";
        value.Inlines.Add(new Run { Text = count.ToString() });
        // Pin the Chinese unit to a Simplified Chinese font instead of relying
        // on the numeral font's CJK fallback (which can use a different glyph form).
        value.Inlines.Add(new Run { Text = " 门", FontFamily = new("Microsoft YaHei UI, Microsoft YaHei"), FontSize = 12, FontWeight = Microsoft.UI.Text.FontWeights.Normal, Foreground = Secondary });
        return Column(Text(label, 11, color: Secondary), value);
    }
    FrameworkElement AttendanceRing(int completed, int total)
    {
        var canvas = new Canvas { Width = 42, Height = 42 };
        var track = new Ellipse { Width = 42, Height = 42, Stroke = Pale, StrokeThickness = 5 };
        canvas.Children.Add(track);
        var fraction = total == 0 ? 0 : Math.Clamp((double)completed / total, 0, 1);
        if (fraction >= 1)
        {
            var full = new Ellipse { Width = 42, Height = 42, Stroke = Green, StrokeThickness = 5 };
            canvas.Children.Add(full);
        }
        else if (fraction > 0)
        {
            var angle = fraction * Math.PI * 2 - Math.PI / 2;
            var figure = new PathFigure { StartPoint = new(21, 2.5) };
            figure.Segments.Add(new ArcSegment { Point = new(21 + 18.5 * Math.Cos(angle), 21 + 18.5 * Math.Sin(angle)), Size = new Size(18.5, 18.5), SweepDirection = SweepDirection.Clockwise, IsLargeArc = fraction > .5 });
            var geometry = new PathGeometry();
            geometry.Figures.Add(figure);
            canvas.Children.Add(new Microsoft.UI.Xaml.Shapes.Path { Data = geometry, Stroke = Green, StrokeThickness = 5, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round });
        }
        var tick = new PathFigure { StartPoint = new(14, 21) };
        tick.Segments.Add(new LineSegment { Point = new(19, 26) });
        tick.Segments.Add(new LineSegment { Point = new(28, 16) });
        var tickGeometry = new PathGeometry();
        tickGeometry.Figures.Add(tick);
        canvas.Children.Add(new Microsoft.UI.Xaml.Shapes.Path { Data = tickGeometry, Stroke = Green, StrokeThickness = 2.2, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, StrokeLineJoin = PenLineJoin.Round });
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(canvas, $"已完成 {completed} 门签到");
        return canvas;
    }
}
