//! Bounded expression entry and arithmetic, independent of the window host.
const std = @import("std");

pub const Model = struct {
    buffer: [256]u8 = undefined,
    len: usize = 0,
    history: [256]u8 = undefined,
    history_len: usize = 0,
    result: [64]u8 = undefined,
    result_len: usize = 0,
    notice: []const u8 = "",
    evaluated: bool = false,
    repeat: ?Operation = null,

    pub fn expression(self: *const Model) []const u8 {
        return self.buffer[0..self.len];
    }

    pub fn display(self: *const Model) []const u8 {
        return if (self.evaluated) self.result[0..self.result_len] else self.expression();
    }

    pub fn clear(self: *Model) void {
        self.* = .{};
    }

    pub fn backspace(self: *Model) void {
        self.notice = "";
        self.evaluated = false;
        self.repeat = null;
        self.len -|= 1;
    }

    pub fn input(self: *Model, char: u8) void {
        if (std.mem.indexOfScalar(u8, "0123456789.+-*/()%", char) == null) return;
        self.repeat = null;
        if (self.evaluated and (std.ascii.isDigit(char) or char == '.' or char == '(')) self.len = 0;
        self.evaluated = false;
        self.notice = "";
        // A decimal starts a number; ignore a second point in that number.
        if (char == '.') {
            var i = self.len;
            while (i > 0 and (std.ascii.isDigit(self.buffer[i - 1]) or self.buffer[i - 1] == '.')) : (i -= 1) {
                if (self.buffer[i - 1] == '.') return;
            }
            if (i == self.len) {
                if (self.len + 2 > self.buffer.len) return self.full();
                self.buffer[self.len] = '0';
                self.len += 1;
            }
        }
        if (self.len == self.buffer.len) return self.full();
        self.buffer[self.len] = char;
        self.len += 1;
    }

    fn full(self: *Model) void {
        self.notice = @import("i18n").tr("Expression is full");
    }

    /// Toggle the trailing operand, including a percentage or grouped result.
    pub fn negate(self: *Model) void {
        self.notice = "";
        self.evaluated = false;
        self.repeat = null;
        var start = self.len;
        while (start > 0 and self.buffer[start - 1] == '%') start -= 1;
        if (start > 0 and self.buffer[start - 1] == ')') {
            var depth: usize = 1;
            start -= 1;
            while (start > 0 and depth > 0) {
                start -= 1;
                if (self.buffer[start] == ')') depth += 1;
                if (self.buffer[start] == '(') depth -= 1;
            }
            if (depth != 0) return;
        } else {
            while (start > 0 and (std.ascii.isDigit(self.buffer[start - 1]) or self.buffer[start - 1] == '.')) start -= 1;
            if (start > 0) {
                var exponent = start;
                if (self.buffer[exponent - 1] == '+' or self.buffer[exponent - 1] == '-') exponent -= 1;
                if (exponent > 0 and (self.buffer[exponent - 1] == 'e' or self.buffer[exponent - 1] == 'E')) {
                    start = exponent - 1;
                    while (start > 0 and (std.ascii.isDigit(self.buffer[start - 1]) or self.buffer[start - 1] == '.')) start -= 1;
                }
            }
        }
        if (start > 0 and self.buffer[start - 1] == '-' and
            (start == 1 or std.mem.indexOfScalar(u8, "+-*/(", self.buffer[start - 2]) != null))
        {
            std.mem.copyForwards(u8, self.buffer[start - 1 ..], self.buffer[start..self.len]);
            self.len -= 1;
        } else {
            if (self.len == self.buffer.len) return self.full();
            std.mem.copyBackwards(u8, self.buffer[start + 1 .. self.len + 1], self.buffer[start..self.len]);
            self.buffer[start] = '-';
            self.len += 1;
        }
    }

    pub fn equals(self: *Model) void {
        if (self.len == 0) return;
        if (self.evaluated) {
            const operation = self.repeat orelse return;
            var operand: [64]u8 = undefined;
            const rhs = formatNumber(&operand, operation.number) catch unreachable;
            const expression_text = std.fmt.bufPrint(&self.history, "{s}{c}{s}{s}", .{
                self.expression(), operation.operator, rhs, if (operation.percent) "%" else "",
            }) catch unreachable;
            @memcpy(self.buffer[0..expression_text.len], expression_text);
            self.len = expression_text.len;
            self.evaluated = false;
        }
        var parser: Parser = .{ .text = self.expression() };
        const evaluation = parser.evaluate() catch |err| {
            self.notice = switch (err) {
                error.DivisionByZero => @import("i18n").tr("Cannot divide by zero"),
                error.Overflow => @import("i18n").tr("Result is too large"),
                else => @import("i18n").tr("Check the expression"),
            };
            return;
        };
        const value = evaluation.number;
        @memcpy(self.history[0..self.len], self.expression());
        self.history_len = self.len;
        // General formatting stays short for very large/small values and
        // retains enough precision to continue calculating from the result.
        var result: [256]u8 = undefined;
        const formatted = formatNumber(&result, value) catch {
            self.notice = @import("i18n").tr("Result is too large");
            return;
        };
        @memcpy(self.buffer[0..formatted.len], formatted);
        self.len = formatted.len;
        // Hide floating-point noise (0.1 + 0.2) in the readout, keeping the
        // full result above for the next operation.
        var rounded: [64]u8 = undefined;
        const scientific = std.fmt.float.render(&rounded, value, .{ .mode = .scientific, .precision = 14 }) catch unreachable;
        const parsed = std.fmt.parseFloat(f64, scientific) catch value;
        const readout = formatNumber(&self.result, if (std.math.isFinite(parsed)) parsed else value) catch unreachable;
        self.result_len = readout.len;
        self.notice = "";
        self.evaluated = true;
        self.repeat = evaluation.repeat;
    }
};

fn formatNumber(buffer: []u8, number: f64) ![]const u8 {
    const value: f64 = if (number == 0) 0 else number;
    const scientific = value != 0 and (@abs(value) >= 1e15 or @abs(value) < 1e-9);
    return std.fmt.float.render(buffer, value, .{ .mode = if (scientific) .scientific else .decimal });
}

const EvalError = error{ InvalidExpression, DivisionByZero, Overflow };

/// The final binary operation, with its right-hand expression already resolved.
const Operation = struct {
    operator: u8,
    number: f64,
    percent: bool = false,

    fn init(operator: u8, rhs: Parser.Value) Operation {
        return .{
            .operator = operator,
            .number = if (rhs.percent) rhs.number * 100 else rhs.number,
            .percent = rhs.percent,
        };
    }
};

const Parser = struct {
    text: []const u8,
    pos: usize = 0,
    depth: usize = 0,

    const Value = struct {
        number: f64,
        /// A percentage operand keeps its meaning through signs and grouping.
        /// Products and sums produce ordinary numbers.
        percent: bool = false,
        repeat: ?Operation = null,
    };

    fn evaluate(self: *Parser) EvalError!Value {
        const value = try self.sum();
        if (self.pos != self.text.len) return error.InvalidExpression;
        return value;
    }

    fn take(self: *Parser, char: u8) bool {
        if (self.pos == self.text.len or self.text[self.pos] != char) return false;
        self.pos += 1;
        return true;
    }

    fn finite(value: f64) EvalError!f64 {
        if (!std.math.isFinite(value)) return error.Overflow;
        return value;
    }

    fn sum(self: *Parser) EvalError!Value {
        var value = try self.product();
        while (self.pos < self.text.len) {
            const subtract = if (self.take('+')) false else if (self.take('-')) true else break;
            const rhs = try self.product();
            // Calculator-style increases/discounts: 200 + 10% = 220.
            // Resolve multiplication/division first, using fractional rates.
            const amount = if (rhs.percent) try finite(value.number * rhs.number) else rhs.number;
            value = .{
                .number = try finite(if (subtract) value.number - amount else value.number + amount),
                .repeat = Operation.init(if (subtract) '-' else '+', rhs),
            };
        }
        return value;
    }

    fn product(self: *Parser) EvalError!Value {
        var value = try self.operand();
        while (self.pos < self.text.len) {
            if (self.take('*')) {
                const rhs = try self.operand();
                value = .{ .number = try finite(value.number * rhs.number), .repeat = Operation.init('*', rhs) };
            } else if (self.take('/')) {
                const rhs = try self.operand();
                if (rhs.number == 0) return error.DivisionByZero;
                value = .{ .number = try finite(value.number / rhs.number), .repeat = Operation.init('/', rhs) };
            } else break;
        }
        return value;
    }

    fn operand(self: *Parser) EvalError!Value {
        if (self.depth >= 32) return error.InvalidExpression;
        self.depth += 1;
        defer self.depth -= 1;
        var negative = false;
        while (self.pos < self.text.len) {
            if (self.take('-')) negative = !negative else if (!self.take('+')) break;
        }
        var value: Value = undefined;
        if (self.take('(')) {
            value = try self.sum();
            if (!self.take(')')) return error.InvalidExpression;
        } else {
            const start = self.pos;
            while (self.pos < self.text.len and (std.ascii.isDigit(self.text[self.pos]) or self.text[self.pos] == '.')) self.pos += 1;
            if (self.take('e') or self.take('E')) {
                _ = self.take('+') or self.take('-');
                while (self.pos < self.text.len and std.ascii.isDigit(self.text[self.pos])) self.pos += 1;
            }
            value = .{ .number = std.fmt.parseFloat(f64, self.text[start..self.pos]) catch return error.InvalidExpression };
        }
        while (self.take('%')) {
            value.number /= 100;
            value.percent = true;
            value.repeat = null;
        }
        if (negative) value.repeat = null;
        value.number = try finite(if (negative) -value.number else value.number);
        return value;
    }
};

test {
    _ = @import("model_tests.zig");
}
