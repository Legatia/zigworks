// What WebView2.h asks of the Windows SDK and Zig's headers lack.
#pragma once
typedef struct EventRegistrationToken {
    __int64 value;
} EventRegistrationToken;
