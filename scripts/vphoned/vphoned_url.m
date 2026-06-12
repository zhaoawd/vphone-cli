/*
 * vphoned_url — URL opening via the entitled uiopen CLI.
 *
 * The in-process LSApplicationWorkspace openURL/openSensitiveURL path returns
 * NO from the daemon context (vphoned isn't entitled for the SpringBoard
 * open-sensitive-url service), so URL open is delegated to uiopen, which is a
 * properly entitled platform binary. See the uiopen bridge note in
 * vphoned_apps.m.
 */

#import "vphoned_url.h"
#import "vphoned_apps.h"
#import "vphoned_protocol.h"

NSDictionary *vp_handle_url_command(NSDictionary *msg) {
  id reqId = msg[@"id"];
  NSString *urlStr = msg[@"url"];

  if (!urlStr) {
    NSMutableDictionary *r = vp_make_response(@"err", reqId);
    r[@"msg"] = @"missing url";
    return r;
  }

  NSURL *url = [NSURL URLWithString:urlStr];
  if (!url) {
    NSMutableDictionary *r = vp_make_response(@"err", reqId);
    r[@"msg"] = [NSString stringWithFormat:@"invalid url: %@", urlStr];
    return r;
  }

  int rc = vp_open_via_uiopen(urlStr, nil);
  NSMutableDictionary *r = vp_make_response(@"open_url", reqId);
  r[@"ok"] = @(rc == 0);
  if (rc != 0) {
    r[@"msg"] = rc < 0
                    ? [NSString stringWithFormat:@"uiopen unavailable for url: %@", urlStr]
                    : [NSString stringWithFormat:@"uiopen exit %d for url: %@", rc, urlStr];
  }
  return r;
}
