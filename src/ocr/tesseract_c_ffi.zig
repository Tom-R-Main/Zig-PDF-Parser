//! Flag-only libtesseract C header check.
//!
//! This module exists to keep the eventual C backend honest: it imports
//! Tesseract's C API header, not the C++ `baseapi.h` surface.

const std = @import("std");

const c = @cImport({
    @cInclude("tesseract/capi.h");
});

test "libtesseract C API header exposes the intended entry points" {
    try std.testing.expect(@hasDecl(c, "TessVersion"));
    try std.testing.expect(@hasDecl(c, "TessBaseAPICreate"));
    try std.testing.expect(@hasDecl(c, "TessBaseAPIDelete"));
    try std.testing.expect(@hasDecl(c, "TessBaseAPISetPageSegMode"));
    try std.testing.expect(@hasDecl(c, "TessBaseAPISetImage"));
    try std.testing.expect(@hasDecl(c, "TessBaseAPISetSourceResolution"));
    try std.testing.expect(@hasDecl(c, "TessBaseAPISetRectangle"));
    try std.testing.expect(@hasDecl(c, "TessBaseAPIRecognize"));
    try std.testing.expect(@hasDecl(c, "TessBaseAPIGetIterator"));
    try std.testing.expect(@hasDecl(c, "TessPageIteratorBoundingBox"));
    try std.testing.expect(@hasDecl(c, "TessResultIteratorGetUTF8Text"));
    try std.testing.expect(@hasDecl(c, "TessResultIteratorConfidence"));
    try std.testing.expect(@hasDecl(c, "TessResultIteratorWordFontAttributes"));
    try std.testing.expect(@hasDecl(c, "TessResultIteratorNext"));
    try std.testing.expect(@hasDecl(c, "TessDeleteText"));
    try std.testing.expect(@hasDecl(c, "TessBaseAPIClear"));
    try std.testing.expect(@hasDecl(c, "TessBaseAPIEnd"));
}
