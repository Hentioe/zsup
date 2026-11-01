# zsup

使用 Zig 编写的进程管理库。

## 安装

添加 `zsup` 到 `build.zig.zon`：

```sh
zig fetch --save git+https://github.com/Hentioe/zsup
```

然后，在 `build.zig`：

```zig
const zsup = b.dependency("zsup", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zsup", zsup.module("zsup"));
```

## 例子

_待写。_
