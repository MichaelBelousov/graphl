const std = @import("std");
const dvui = @import("dvui");

pub fn iconWidget(src: std.builtin.SourceLocation, name: []const u8, tvg_bytes: []const u8, opts: dvui.Options) !dvui.IconWidget {
    var iw = try dvui.IconWidget.init(src, name, tvg_bytes, opts);
    try iw.install();
    try iw.draw();
    iw.deinit();
    return iw;
}

pub const ButtonIconResult = struct {
    clicked: bool = false,
    icon: dvui.IconWidget,
};

pub fn buttonIconResult(src: std.builtin.SourceLocation, name: []const u8, tvg_bytes: []const u8, init_opts: dvui.ButtonWidget.InitOptions, opts: dvui.Options) !ButtonIconResult {
    const defaults = dvui.Options{ .padding = dvui.Rect.all(4) };
    var bw = dvui.ButtonWidget.init(src, init_opts, defaults.override(opts));
    try bw.install();
    bw.processEvents();
    try bw.drawBackground();

    // pass min_size_content through to the icon so that it will figure out the
    // min width based on the height
    const icon_in_btn = try iconWidget(@src(), name, tvg_bytes, opts.strip().override(.{ .gravity_x = 0.5, .gravity_y = 0.5, .min_size_content = opts.min_size_content, .expand = .ratio }));

    const click = bw.clicked();
    try bw.drawFocus();
    bw.deinit();

    return .{
        .clicked = click,
        .icon = icon_in_btn,
    };
}
