/*
 * vphoned_protocol — Length-prefixed JSON framing over vsock.
 *
 * Each message: [uint32 big-endian length][UTF-8 JSON payload]
 */

#pragma once
#import <Foundation/Foundation.h>

#define PROTOCOL_VERSION 1

BOOL vp_read_fully(int fd, void *buf, size_t count);
BOOL vp_write_fully(int fd, const void *buf, size_t count);

/// Discard exactly `size` bytes from fd. Used to keep protocol in sync on error paths.
void vp_drain(int fd, size_t size);

NSDictionary *vp_read_message(int fd);

/// Write one length-prefixed JSON frame. Thread-safe: serializes against
/// other vp_write_message / vp_write_with_payload / vp_writer_lock callers
/// on the same process, so concurrent workers cannot interleave bytes on
/// the shared client fd.
BOOL vp_write_message(int fd, NSDictionary *dict);

/// Write a JSON frame immediately followed by a raw binary payload, as
/// one indivisible writer-side operation.
BOOL vp_write_with_payload(int fd, NSDictionary *dict, const void *payload, size_t payloadLen);

/// Manual writer lock for callers that need to stream a multi-chunk payload
/// after a single JSON header (e.g. file_get). Use vp_write_message_locked
/// for the header, then vp_write_fully for the streamed bytes, then unlock.
void vp_writer_lock(void);
void vp_writer_unlock(void);
BOOL vp_write_message_locked(int fd, NSDictionary *dict);

/// Build a response dict with protocol version, type, and optional request ID echo.
NSMutableDictionary *vp_make_response(NSString *type, id reqId);
