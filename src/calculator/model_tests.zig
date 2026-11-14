const std = @import("std");
const Model = @import("model.zig").Model;

fn enter(model: *Model, expression: []const u8) void {
    for (expression) |char| model.input(char);
}

fn expectResult(model: *Model, expected: []const u8) !void {
    model.equals();
    try std.testing.expectEqualStrings("", model.notice);
    try std.testing.expect(model.evaluated);
    try std.testing.expectEqualStrings(expected, model.display());
}

test "calculator percentages follow the arithmetic operator and grouping" {
    const cases = [_][2][]const u8{
        .{ "100+5%", "105" },
        .{ "200+10%", "220" },
        .{ "200-10%", "180" },
        .{ "200*10%", "20" },
        .{ "200/10%", "2000" },
        .{ "10%*200", "20" },
        .{ "10%/200", "0.0005" },
        .{ "5%", "0.05" },
        .{ "200+10%+5%", "231" },
        .{ "200-10%-5%", "171" },
        .{ "200+10%-10%", "198" },
        .{ "200+0%", "200" },
        .{ "200-100%", "0" },
        .{ "200+150%", "500" },
        .{ "0+5%", "0" },
        .{ "-200+10%", "-220" },
        .{ "200+-10%", "180" },
        .{ "200--10%", "220" },
        .{ "200+2.5%", "205" },
        .{ "200+(5+5)%", "220" },
        .{ "200+(10%)", "220" },
        .{ "200+(-(10%))", "180" },
        .{ "(100+5)%", "1.05" },
        .{ "(200+10%)*2", "440" },
        .{ "100+200*5%", "110" },
        .{ "100+5%*200", "110" },
        .{ "100+200/5%", "4100" },
        .{ "100*2+5%", "210" },
        .{ "50%%", "0.005" },
    };
    for (cases) |case| {
        var model: Model = .{};
        enter(&model, case[0]);
        errdefer std.debug.print("expression: {s}\n", .{case[0]});
        try expectResult(&model, case[1]);
        try std.testing.expectEqualStrings(case[0], model.history[0..model.history_len]);
    }
}

test "calculator preserves precedence, associativity and readable decimals" {
    const cases = [_][2][]const u8{
        .{ "2+3*4", "14" },    .{ "(2+3)*4", "20" },
        .{ "20/5*2", "8" },    .{ "20-5-2", "13" },
        .{ "2*-3", "-6" },     .{ "-(2+3)", "-5" },
        .{ ".5+.25", "0.75" }, .{ "0.1+0.2", "0.3" },
        .{ "-0", "0" },        .{ "1/10000000000", "1e-10" },
    };
    for (cases) |case| {
        var model: Model = .{};
        enter(&model, case[0]);
        try expectResult(&model, case[1]);
    }
}

test "calculator continues from results and starts fresh on numeric entry" {
    var model: Model = .{};
    enter(&model, "200+10%");
    try expectResult(&model, "220");
    enter(&model, "-5%");
    try expectResult(&model, "209");
    enter(&model, "1/10000000000");
    try expectResult(&model, "1e-10");
    enter(&model, "*10000000000");
    try expectResult(&model, "1");
    enter(&model, "0.1+0.2");
    try expectResult(&model, "0.3");
    enter(&model, "*10");
    try expectResult(&model, "3");
}

test "calculator repeats the final operation with precedence and percentages" {
    const cases = [_][4][]const u8{
        .{ "2+3", "5", "8", "11" },
        .{ "10-2", "8", "6", "4" },
        .{ "3*2", "6", "12", "24" },
        .{ "16/2", "8", "4", "2" },
        .{ "2+3*4", "14", "26", "38" },
        .{ "(2+3)*4", "20", "80", "320" },
        .{ "20-5-2", "13", "11", "9" },
        .{ "2*(3+4)", "14", "98", "686" },
        .{ "2*-3", "-6", "18", "-54" },
        .{ "200+10%", "220", "242", "266.2" },
        .{ "200-10%", "180", "162", "145.8" },
        .{ "200*10%", "20", "2", "0.2" },
        .{ "200/10%", "2000", "20000", "200000" },
        .{ "200+(5+5)%", "220", "242", "266.2" },
        .{ "7", "7", "7", "7" },
        .{ "5%", "0.05", "0.05", "0.05" },
    };
    for (cases) |case| {
        var model: Model = .{};
        enter(&model, case[0]);
        errdefer std.debug.print("expression: {s}\n", .{case[0]});
        for (case[1..]) |expected| try expectResult(&model, expected);
    }
    var model: Model = .{};
    enter(&model, "2+3");
    try expectResult(&model, "5");
    try expectResult(&model, "8");
    try std.testing.expectEqualStrings("5+3", model.history[0..model.history_len]);
}

test "calculator resets repeated equals when entering or editing a calculation" {
    var model: Model = .{};
    enter(&model, "2+3");
    try expectResult(&model, "5");
    enter(&model, "7");
    try expectResult(&model, "7");
    try expectResult(&model, "7");
    enter(&model, "*2");
    try expectResult(&model, "14");
    try expectResult(&model, "28");
    model.backspace();
    try expectResult(&model, "2");
    try expectResult(&model, "2");
    enter(&model, "+3");
    try expectResult(&model, "5");
    model.negate();
    try expectResult(&model, "-5");
    try expectResult(&model, "-5");
    model.clear();
    model.equals();
    try std.testing.expectEqualStrings("", model.display());
    enter(&model, "4");
    try expectResult(&model, "4");
    try expectResult(&model, "4");
}

test "calculator sign toggle handles numbers, percentages and groups" {
    const cases = [_][2][]const u8{
        .{ "200+10%", "180" }, .{ "200+(5+5)%", "180" },
        .{ "2*(3+4)", "-14" }, .{ "2+3", "-1" },
    };
    for (cases) |case| {
        var model: Model = .{};
        enter(&model, case[0]);
        model.negate();
        model.negate();
        try std.testing.expectEqualStrings(case[0], model.expression());
        model.negate();
        try expectResult(&model, case[1]);
    }
    var model: Model = .{};
    enter(&model, "1/10000000000");
    try expectResult(&model, "1e-10");
    model.negate();
    try expectResult(&model, "-1e-10");
}

test "calculator rejects invalid expressions and allows correction" {
    for ([_][]const u8{ "1/0", "100/0%", "1/(2-2)", "1+", "(1+2", "1+2)", "2(3)", "%" }) |expression| {
        var model: Model = .{};
        enter(&model, expression);
        model.equals();
        try std.testing.expect(!model.evaluated);
        try std.testing.expect(model.notice.len > 0);
        try std.testing.expectEqualStrings(expression, model.expression());
    }
    var model: Model = .{};
    enter(&model, "100/0%");
    model.equals();
    model.backspace();
    model.backspace();
    enter(&model, "5%");
    try expectResult(&model, "2000");
    model.clear();
    try std.testing.expectEqualStrings("", model.display());
    try std.testing.expectEqual(@as(usize, 0), model.history_len);
}

test "calculator bounds entry and rejects overflowing arithmetic" {
    var model: Model = .{};
    for (0..256) |_| model.input('9');
    model.input('9');
    try std.testing.expectEqual(@as(usize, 256), model.len);
    try std.testing.expect(model.notice.len > 0);
    model.equals();
    try std.testing.expect(model.evaluated);
    model.input('*');
    for (0..100) |_| model.input('9');
    model.equals();
    try std.testing.expect(!model.evaluated);
    try std.testing.expect(model.notice.len > 0);
}
