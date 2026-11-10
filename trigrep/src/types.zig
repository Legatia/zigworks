//! File types for `-t`/`-T`, using ripgrep's definitions for the common ones, so
//! `-t rust` means the same in both tools.

const std = @import("std");

pub const Type = struct { name: []const u8, globs: []const []const u8 };

pub const all = [_]Type{
    .{ .name = "asm", .globs = &.{ "*.S", "*.asm", "*.s" } },
    .{ .name = "c", .globs = &.{ "*.[chH]", "*.[chH].in", "*.cats" } },
    .{ .name = "clojure", .globs = &.{ "*.clj", "*.cljc", "*.cljs", "*.cljx" } },
    .{ .name = "cmake", .globs = &.{ "*.cmake", "CMakeLists.txt" } },
    .{ .name = "cpp", .globs = &.{ "*.[ChH]", "*.[ChH].in", "*.[ch]pp", "*.[ch]pp.in", "*.[ch]xx", "*.[ch]xx.in", "*.cc", "*.cc.in", "*.hh", "*.hh.in", "*.inl" } },
    .{ .name = "cs", .globs = &.{"*.cs"} },
    .{ .name = "csharp", .globs = &.{"*.cs"} },
    .{ .name = "css", .globs = &.{ "*.css", "*.scss" } },
    .{ .name = "cuda", .globs = &.{ "*.cu", "*.cuh" } },
    .{ .name = "d", .globs = &.{"*.d"} },
    .{ .name = "dart", .globs = &.{"*.dart"} },
    .{ .name = "docker", .globs = &.{"*Dockerfile*"} },
    .{ .name = "elixir", .globs = &.{ "*.eex", "*.ex", "*.exs", "*.heex", "*.leex", "*.livemd" } },
    .{ .name = "erlang", .globs = &.{ "*.erl", "*.hrl" } },
    .{ .name = "go", .globs = &.{"*.go"} },
    .{ .name = "gradle", .globs = &.{ "*.gradle", "*.gradle.kts", "gradle-wrapper.*", "gradle.properties", "gradlew", "gradlew.bat" } },
    .{ .name = "graphql", .globs = &.{ "*.graphql", "*.graphqls" } },
    .{ .name = "haskell", .globs = &.{ "*.c2hs", "*.cpphs", "*.hs", "*.hsc", "*.lhs" } },
    .{ .name = "html", .globs = &.{ "*.ejs", "*.htm", "*.html" } },
    .{ .name = "java", .globs = &.{ "*.java", "*.jsp", "*.jspx", "*.properties" } },
    .{ .name = "js", .globs = &.{ "*.cjs", "*.js", "*.jsx", "*.mjs", "*.vue" } },
    .{ .name = "json", .globs = &.{ "*.json", "*.sarif", "composer.lock" } },
    .{ .name = "jsonl", .globs = &.{"*.jsonl"} },
    .{ .name = "julia", .globs = &.{"*.jl"} },
    .{ .name = "kotlin", .globs = &.{ "*.kt", "*.kts" } },
    .{ .name = "less", .globs = &.{"*.less"} },
    .{ .name = "lua", .globs = &.{"*.lua"} },
    .{ .name = "make", .globs = &.{ "*.mak", "*.mk", "Makefile.*", "[Gg][Nn][Uu]makefile", "[Gg][Nn][Uu]makefile.am", "[Gg][Nn][Uu]makefile.in", "[Mm]akefile", "[Mm]akefile.am", "[Mm]akefile.in" } },
    .{ .name = "markdown", .globs = &.{ "*.markdown", "*.md", "*.mdown", "*.mdwn", "*.mdx", "*.mkd", "*.mkdn" } },
    .{ .name = "md", .globs = &.{ "*.markdown", "*.md", "*.mdown", "*.mdwn", "*.mdx", "*.mkd", "*.mkdn" } },
    .{ .name = "nix", .globs = &.{"*.nix"} },
    .{ .name = "objc", .globs = &.{ "*.h", "*.m" } },
    .{ .name = "ocaml", .globs = &.{ "*.ml", "*.mli", "*.mll", "*.mly" } },
    .{ .name = "perl", .globs = &.{ "*.PL", "*.perl", "*.pl", "*.plh", "*.plx", "*.pm", "*.t" } },
    .{ .name = "php", .globs = &.{ "*.php", "*.php3", "*.php4", "*.php5", "*.php7", "*.php8", "*.pht", "*.phtml" } },
    .{ .name = "proto", .globs = &.{"*.proto"} },
    .{ .name = "protobuf", .globs = &.{"*.proto"} },
    .{ .name = "py", .globs = &.{ "*.py", "*.pyi" } },
    .{ .name = "python", .globs = &.{ "*.py", "*.pyi" } },
    .{ .name = "r", .globs = &.{ "*.R", "*.Rmd", "*.Rnw", "*.r", "*.rmd", "*.rnw" } },
    .{ .name = "ruby", .globs = &.{ "*.gemspec", "*.rake", "*.rb", "*.rbw", ".irbrc", "Gemfile", "Rakefile", "config.ru" } },
    .{ .name = "rust", .globs = &.{"*.rs"} },
    .{ .name = "sass", .globs = &.{ "*.sass", "*.scss" } },
    .{ .name = "scala", .globs = &.{ "*.sbt", "*.scala" } },
    .{ .name = "sh", .globs = &.{ "*.bash", "*.bashrc", "*.csh", "*.cshrc", "*.env", "*.ksh", "*.kshrc", "*.sh", "*.tcsh", "*.zsh", ".bash_login", ".bash_logout", ".bash_profile", ".bashrc", ".cshrc", ".env", ".kshrc", ".login", ".logout", ".profile", ".tcshrc", ".zlogin", ".zlogout", ".zprofile", ".zshenv", ".zshrc", "bash_login", "bash_logout", "bash_profile", "bashrc", "profile", "zlogin", "zlogout", "zprofile", "zshenv", "zshrc" } },
    .{ .name = "solidity", .globs = &.{"*.sol"} },
    .{ .name = "sql", .globs = &.{ "*.psql", "*.sql" } },
    .{ .name = "svelte", .globs = &.{ "*.svelte", "*.svelte.ts" } },
    .{ .name = "swift", .globs = &.{"*.swift"} },
    .{ .name = "tf", .globs = &.{ "*.terraform.lock.hcl", "*.terraformrc", "*.tf", "*.tf.json", "*.tfrc", "*.tfvars", "*.tfvars.json", "terraform.rc" } },
    .{ .name = "toml", .globs = &.{ "*.toml", "Cargo.lock" } },
    .{ .name = "ts", .globs = &.{ "*.cts", "*.mts", "*.ts", "*.tsx" } },
    .{ .name = "typescript", .globs = &.{ "*.cts", "*.mts", "*.ts", "*.tsx" } },
    .{ .name = "txt", .globs = &.{"*.txt"} },
    .{ .name = "vim", .globs = &.{ "*.vim", ".gvimrc", ".vimrc", "_gvimrc", "_vimrc", "gvimrc", "vimrc" } },
    .{ .name = "vue", .globs = &.{"*.vue"} },
    .{ .name = "xml", .globs = &.{ "*.dtd", "*.rng", "*.sch", "*.xhtml", "*.xjb", "*.xml", "*.xml.dist", "*.xsd", "*.xsl", "*.xslt" } },
    .{ .name = "yaml", .globs = &.{ "*.yaml", "*.yml" } },
    .{ .name = "zig", .globs = &.{"*.zig"} },
};

pub fn find(name: []const u8) ?Type {
    for (all) |t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

pub fn names(buf: []u8) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    for (all, 0..) |t, i| {
        if (i > 0) w.writeAll(", ") catch break;
        w.writeAll(t.name) catch break;
    }
    return w.buffered();
}
