/*
 * vphoned_location — CoreLocation simulation via CLSimulationManager.
 *
 * Uses private CLSimulationManager API to inject simulated GPS coordinates
 * into the guest. Probes available selectors at runtime since the API
 * varies across iOS versions.
 */

#pragma once
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, VPLocationProtocolResult) {
  VPLocationProtocolOK = 0,
  VPLocationProtocolUnavailable,
  VPLocationProtocolInvalid,
  VPLocationProtocolGenerationConflict,
  VPLocationProtocolSequenceConflict,
};

/// Load CoreLocation and probe CLSimulationManager selectors. Returns NO on failure.
BOOL vp_location_load(void);

/// Whether location simulation is available (load succeeded).
BOOL vp_location_available(void);

/// Bind subsequent owned deliveries to a host generation. Repeating begin is
/// the reconnect handshake and resets the guest-local delivery sequence.
VPLocationProtocolResult vp_location_begin(NSString *generation);

/// Apply one generation-bound delivery. The first sequence after begin may be
/// any non-negative value; subsequent values must be contiguous. An identical
/// retry of the last sequence succeeds without applying the location twice.
VPLocationProtocolResult vp_location_simulate_owned(
    NSString *generation, NSInteger deliverySequence,
    double lat, double lon, double alt,
    double hacc, double vacc,
    double speed, double course, double timestamp,
    BOOL *idempotent);

/// Clear only the source owned by generation. Repeating the last successful
/// clear is idempotent; another generation is rejected.
VPLocationProtocolResult vp_location_clear_owned(
    NSString *generation, BOOL *idempotent);

/// Simulate a GPS location update. Returns NO when simulation is unavailable
/// (daemon not loaded / no set-location selector) or the injection threw.
BOOL vp_location_simulate(double lat, double lon, double alt,
                           double hacc, double vacc,
                           double speed, double course);

/// Clear simulated location. Returns NO when no clear selector was found
/// (capability does not require one) or the clear threw.
BOOL vp_location_clear(void);
