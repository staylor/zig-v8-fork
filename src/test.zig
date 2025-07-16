const std = @import("std");
const v8 = @import("v8.zig");

const Allocator = std.mem.Allocator;

const t = std.testing;
test {
    // Based on https://chromium.googlesource.com/v8/v8/+/branch-heads/6.8/samples/hello-world.cc

    const platform = v8.Platform.initDefault(0, true);
    defer platform.deinit();

    v8.initV8Platform(platform);
    v8.initV8();
    defer {
        _ = v8.deinitV8();
        v8.deinitV8Platform();
    }

    var params = v8.initCreateParams();
    params.array_buffer_allocator = v8.createDefaultArrayBufferAllocator();
    defer v8.destroyArrayBufferAllocator(params.array_buffer_allocator.?);

    var isolate = v8.Isolate.init(&params);
    defer isolate.deinit();

    isolate.enter();
    defer isolate.exit();

    isolate.setHostImportModuleDynamicallyCallback(dynamicModuleCallback);

    // Create a stack-allocated handle scope.
    var hscope: v8.HandleScope = undefined;
    hscope.init(isolate);
    defer hscope.deinit();

    // Create a new context.
    var context = v8.Context.init(isolate, null, null);
    context.enter();
    defer context.exit();

    const script_name = v8.String.initUtf8(isolate, "test");
    const origin = v8.ScriptOrigin.init(
        script_name.toValue(),
        0, // resource_line_offset
        0, // resource_column_offset
        false, // resource_is_shared_cross_origin
        -1, // script_id
        null, // source_map_url
        false, // resource_is_opaque
        false, // is_wasm
        true, // is_module
        null, // host_defined_options
    );

    const script_source = v8.String.initUtf8(isolate,
        \\ import * as a from "sub-1";
        \\ import("./sub-2.js");
    );

    var script_comp_source: v8.ScriptCompilerSource = undefined;
    v8.ScriptCompilerSource.init(&script_comp_source, script_source, origin, null);
    defer script_comp_source.deinit();

    const m = try v8.ScriptCompiler.compileModule(
        isolate,
        &script_comp_source,
        .kNoCompileOptions,
        .kNoCacheNoReason,
    );
    const requests = m.getModuleRequests();

    for (0..requests.length()) |i| {
        const req = requests.get(context, @intCast(i)).castTo(v8.ModuleRequest);
        const specifier = try jsStringToZig(t.allocator, isolate, req.getSpecifier());
        defer t.allocator.free(specifier);
        std.debug.print("{d} {s}\n", .{i, specifier});
    }

    var tc: v8.TryCatch = undefined;
    v8.TryCatch.init(&tc, isolate);
    defer tc.deinit();

    _ = m.instantiate(context, staticModuleCallback) catch {
        const exception = try jsValueToString(t.allocator, isolate, context, tc.getException().?);
        defer t.allocator.free(exception);
        std.debug.print("caught: {s}\n", .{exception});
        return error.ModuleInstantiationError;
    };
    _ = try m.evaluate(context);
}

pub fn jsValueToString(allocator: Allocator, isolate: v8.Isolate, ctx: v8.Context, val: v8.Value) ![]const u8 {
    const str = try val.toString(ctx);
    return jsStringToZig(allocator, isolate, str);
}

pub fn jsStringToZig(allocator: Allocator, isolate: v8.Isolate, str: v8.String) ![]const u8 {
    const len = str.lenUtf8(isolate);
    const buf = try allocator.alloc(u8, len);
    _ = str.writeUtf8(isolate, buf);
    return buf;
}

fn staticModuleCallback(
    c_context: ?*const v8.C_Context,
    c_specifier: ?*const v8.C_String,
    import_attributes: ?*const v8.C_FixedArray,
    c_referrer: ?*const v8.C_Module,
) callconv(.C) ?*const v8.C_Module {
    _ = import_attributes;
    _ = c_referrer;

    const context = v8.Context{.handle = c_context.?};
    const isolate = context.getIsolate();
    const specifier = jsStringToZig(t.allocator, isolate, .{ .handle = c_specifier.? }) catch unreachable;
    defer t.allocator.free(specifier);
    std.debug.print("static callback: {s}\n", .{specifier});

    const origin = v8.ScriptOrigin.init(
        .{.handle = c_specifier.?},
        0, // resource_line_offset
        0, // resource_column_offset
        false, // resource_is_shared_cross_origin
        -1, // script_id
        null, // source_map_url
        false, // resource_is_opaque
        false, // is_wasm
        true, // is_module
        null, // host_defined_options
    );

    const script_source = v8.String.initUtf8(isolate, "");
    var script_comp_source: v8.ScriptCompilerSource = undefined;
    v8.ScriptCompilerSource.init(&script_comp_source, script_source, origin, null);
    defer script_comp_source.deinit();

    const m = v8.ScriptCompiler.compileModule(
        isolate,
        &script_comp_source,
        .kNoCompileOptions,
        .kNoCacheNoReason,
    ) catch unreachable;
    return m.handle;
}

fn dynamicModuleCallback(
    c_context: ?*const v8.c.Context,
    host_defined_options: ?*const v8.c.Data,
    resource_name: ?*const v8.c.Value,
    c_specifier: ?*const v8.c.String,
    import_attrs: ?*const v8.c.FixedArray,
) callconv(.c) ?*v8.c.Promise {
    _ = host_defined_options;
    _ = resource_name;
    _ = import_attrs;

    const context = v8.Context{.handle = c_context.?};
    const isolate = context.getIsolate();
    const specifier = jsStringToZig(t.allocator, isolate, .{ .handle = c_specifier.? }) catch unreachable;
    defer t.allocator.free(specifier);
    std.debug.print("dynamic callback: {s}\n", .{specifier});

    const resolver = v8.PromiseResolver.init(context);
    const promise = resolver.getPromise();
    return @constCast(promise.handle);
}
