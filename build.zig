const std = @import("std");

pub const TranslateC = @import("build/TranslateC.zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const skip_debug = b.option(bool, "skip-debug", "Main test suite skips debug builds") orelse false;
    const skip_release = b.option(bool, "skip-release", "Main test suite skips release builds") orelse false;
    const skip_release_small = b.option(bool, "skip-release-small", "Main test suite skips release-small builds") orelse skip_release;
    const skip_release_fast = b.option(bool, "skip-release-fast", "Main test suite skips release-fast builds") orelse skip_release;
    const skip_release_safe = b.option(bool, "skip-release-safe", "Main test suite skips release-safe builds") orelse skip_release;
    const skip_translate = b.option(bool, "skip-translate", "Main test suite skips translate tests") orelse false;
    const skip_run_translated = b.option(bool, "skip-run-translated", "Main test suite skips run-translated tests") orelse false;
    const use_llvm = b.option(bool, "llvm", "Use LLVM backend to generate aro executable");

    const aro = b.dependency("aro", .{
        .target = target,
        .optimize = optimize,
    });

    const c_builtins = b.addModule("c_builtins", .{
        .root_source_file = b.path("lib/c_builtins.zig"),
    });

    const helpers = b.addModule("helpers", .{
        .root_source_file = b.path("lib/helpers.zig"),
    });

    const translate_c_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{
                .name = "c_builtins",
                .module = c_builtins,
            },
            .{
                .name = "helpers",
                .module = helpers,
            },
        },
    });

    const exe = b.addExecutable(.{
        .name = "translate-c",
        .root_module = translate_c_module,
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    exe.root_module.addImport("aro", aro.module("aro"));
    b.installDirectory(.{
        .source_dir = aro.path("include"),
        .install_dir = .prefix,
        .install_subdir = "include",
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run translate-c");
    run_step.dependOn(&run_cmd.step);

    const optimization_modes: []const std.builtin.OptimizeMode = modes: {
        var chosen_opt_modes_buf: [4]std.builtin.OptimizeMode = undefined;
        var chosen_mode_index: usize = 0;
        if (!skip_debug) {
            chosen_opt_modes_buf[chosen_mode_index] = .Debug;
            chosen_mode_index += 1;
        }
        if (!skip_release_safe) {
            chosen_opt_modes_buf[chosen_mode_index] = .ReleaseSafe;
            chosen_mode_index += 1;
        }
        if (!skip_release_fast) {
            chosen_opt_modes_buf[chosen_mode_index] = .ReleaseFast;
            chosen_mode_index += 1;
        }
        if (!skip_release_small) {
            chosen_opt_modes_buf[chosen_mode_index] = .ReleaseSmall;
            chosen_mode_index += 1;
        }
        break :modes chosen_opt_modes_buf[0..chosen_mode_index];
    };

    const test_step = b.step("test", "Run all tests");

    const fmt_dirs: []const []const u8 = &.{ "build", "src", "test" };
    b.step("fmt", "Modify source files in place to have conforming formatting")
        .dependOn(&b.addFmt(.{ .paths = fmt_dirs }).step);

    const test_fmt = b.step("test-fmt", "Check source files having conforming formatting");
    test_fmt.dependOn(&b.addFmt(.{ .paths = fmt_dirs, .check = true }).step);
    test_step.dependOn(test_fmt);

    {
        const unit_test_step = b.step("test-unit", "Run unit tests");
        for (optimization_modes) |mode| {
            const unit_tests = b.addTest(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = mode,
            });
            unit_tests.root_module.addImport("aro", aro.module("aro"));
            unit_tests.root_module.addImport("helpers", helpers);
            unit_tests.root_module.addImport("c_builtins", c_builtins);
            const run_unit_tests = b.addRunArtifact(unit_tests);
            unit_test_step.dependOn(&run_unit_tests.step);
        }
        test_step.dependOn(unit_test_step);
    }

    const translate_exes = blk: {
        // Use symlink to get the include dir in the exe path without installing both.
        const aro_include = aro.path("include").getPath3(b, null);
        const resolved_aro_include = b.pathResolve(&.{ aro_include.root_dir.path orelse ".", aro_include.sub_path });

        const dest_dir = b.cache_root.join(b.allocator, &.{"include"}) catch @panic("oom");
        std.fs.symLinkAbsolute(resolved_aro_include, dest_dir, .{ .is_directory = true }) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => @panic("failed to symlink"),
        };

        var exes: [4]*std.Build.Step.Compile = undefined;
        for (optimization_modes, 0..) |mode, i| {
            const test_aro = b.dependency("aro", .{
                .target = target,
                .optimize = mode,
            });
            const test_exe = b.addExecutable(.{
                .name = "translate-c",
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = mode,
                .use_llvm = use_llvm,
                .use_lld = use_llvm,
            });
            test_exe.root_module.addImport("aro", test_aro.module("aro"));
            test_exe.root_module.addImport("helpers", helpers);
            test_exe.root_module.addImport("c_builtins", c_builtins);

            // Ensure that a binary is emitted.
            _ = test_exe.getEmittedBin();
            exes[i] = test_exe;
        }
        break :blk exes[0..optimization_modes.len];
    };

    {
        const macro_test_step = b.step("test-macros", "Run unit tests");
        for (optimization_modes, translate_exes) |mode, translate_exe| {
            const macro_tests = b.addTest(.{
                .root_source_file = b.path("test/macros.zig"),
                .target = target,
                .optimize = mode,
            });
            macro_tests.root_module.addImport("macros.h", TranslateC.create(b, .{
                .root_source_file = b.path("test/macros.h"),
                .target = target,
                .optimize = mode,
                .translate_c_exe = translate_exe,
                .builtins_module = c_builtins,
                .helpers_module = helpers,
            }).createModule());
            macro_tests.root_module.addImport("macros_not_utf8.h", TranslateC.create(b, .{
                .root_source_file = b.path("test/macros_not_utf8.h"),
                .target = target,
                .optimize = mode,
                .translate_c_exe = translate_exe,
                .builtins_module = c_builtins,
                .helpers_module = helpers,
            }).createModule());

            const run_macro_tests = b.addRunArtifact(macro_tests);
            macro_test_step.dependOn(&run_macro_tests.step);
            macro_test_step.dependOn(&translate_exe.step);
        }
        test_step.dependOn(macro_test_step);
    }

    {
        const example_test_step = b.step("test-examples", "Test examples");

        // const compile_c = b.dependency("examples_compile_c", .{});
        // example_test_step.dependOn(compile_c.builder.default_step);

        // const import_header = b.dependency("examples_import_header", .{});
        // example_test_step.dependOn(import_header.builder.default_step);

        test_step.dependOn(example_test_step);
    }

    try @import("test/cases.zig").addCaseTests(
        b,
        test_step,
        translate_exes,
        c_builtins,
        helpers,
        target,
        skip_translate,
        skip_run_translated,
    );
}
