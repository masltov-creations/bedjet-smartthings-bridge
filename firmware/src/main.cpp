#include <Arduino.h>
#include <ArduinoJson.h>
#include <BLEDevice.h>
#include <ESPmDNS.h>
#include <Preferences.h>
#include <Update.h>
#include <WebServer.h>
#include <WiFi.h>
#include <mbedtls/md.h>
#include <mbedtls/sha256.h>
#include <vector>

#ifdef __has_include
#if __has_include("wifi_secrets.h")
#include "wifi_secrets.h"
#endif
#endif

#ifndef WIFI_SSID
#define WIFI_SSID ""
#endif

#ifndef WIFI_PASSWORD
#define WIFI_PASSWORD ""
#endif

#ifndef MDNS_HOSTNAME
#define MDNS_HOSTNAME "bedjet-gateway"
#endif

#ifndef BEDJET_ACTIVITY_RGB_PIN
#ifdef RGB_BUILTIN
#define BEDJET_ACTIVITY_RGB_PIN RGB_BUILTIN
#else
#define BEDJET_ACTIVITY_RGB_PIN 48
#endif
#endif

#ifndef BEDJET_SIMULATED_BACKEND
#define BEDJET_SIMULATED_BACKEND 1
#endif

namespace {

constexpr const char *kPreferenceNamespace = "bedjet";
constexpr uint16_t kHttpPort = 80;
constexpr size_t kNonceCacheSize = 64;
constexpr size_t kMaxJsonBodyBytes = 4096;
constexpr const char *kSetupApSsid = "BedJetGatewaySetup";
constexpr const char *kBedJetServiceUuid = "00001000-bed0-0080-aa55-4265644a6574";
constexpr const char *kBedJetStatusUuid = "00002000-bed0-0080-aa55-4265644a6574";
constexpr const char *kBedJetCommandUuid = "00002004-bed0-0080-aa55-4265644a6574";
constexpr const char *kBedJetNameUuid = "00002001-bed0-0080-aa55-4265644a6574";
constexpr const char *kFirmwareBuildId = __DATE__ " " __TIME__;
constexpr uint32_t kFirmwareApiVersion = 3;
constexpr int kDefaultSmartThingsPollIntervalSeconds = 15;
constexpr int kMinSmartThingsPollIntervalSeconds = 5;
constexpr int kMaxSmartThingsPollIntervalSeconds = 120;
constexpr int kActivityLightPin = BEDJET_ACTIVITY_RGB_PIN;
constexpr bool kActivityLightAvailable = kActivityLightPin >= 0;

enum BedjetButton : uint8_t {
  BTN_OFF = 0x1,
  BTN_COOL = 0x2,
  BTN_HEAT = 0x3,
  BTN_TURBO = 0x4,
  BTN_DRY = 0x5,
  BTN_EXTHT = 0x6,
  MAGIC_CONNTEST = 0x42
};

enum BedjetCommand : uint8_t {
  CMD_BUTTON = 0x1,
  CMD_SET_TEMP = 0x3,
  CMD_SET_FAN = 0x7
};

struct PairSlot {
  bool paired = false;
  String side;
  String deviceId;
  String displayName;
  String pairedAt;
};

struct SideStatus {
  String power = "off";
  String mode = "cool";
  int fanStep = 8;
  int targetTemperatureC = 24;
  int currentTemperatureC = 23;
  bool bleReleased = false;
};

struct ParsedBedJetStatus {
  bool valid = false;
  bool partial = false;
  bool ackOnly = false;
  String power = "off";
  String mode = "cool";
  int fanStep = 8;
  int targetTemperatureC = 24;
  int currentTemperatureC = 23;
};

struct SideState {
  PairSlot slot;
  SideStatus status;
};

struct AuthState {
  bool claimed = false;
  String gatewayId;
  String sharedSecret;
  String claimedAt;
  String recentNonces[kNonceCacheSize];
  size_t nonceIndex = 0;
};

struct WiFiConfigState {
  String ssid;
  String password;
  String hostname;
};

struct ActivityLightConfigState {
  bool enabled = true;
};

struct RgbColor {
  uint8_t red = 0;
  uint8_t green = 0;
  uint8_t blue = 0;
};

struct ActivityLightPulseState {
  bool active = false;
  RgbColor color;
  unsigned long startedAtMs = 0;
  unsigned long durationMs = 0;
};

struct ScanCandidate {
  String deviceId;
  String displayName;
  int rssi = 0;
};

WebServer server(kHttpPort);
Preferences preferences;
SideState leftState;
SideState rightState;
AuthState authState;
WiFiConfigState wifiConfig;
ActivityLightConfigState activityLightConfig;
ActivityLightPulseState activityLightPulse;
int smartthingsPollIntervalSeconds = kDefaultSmartThingsPollIntervalSeconds;
bool mdnsStarted = false;
bool restartScheduled = false;
unsigned long restartAtMs = 0;

struct OtaUpdateState {
  bool active = false;
  bool started = false;
  bool completed = false;
  bool ok = false;
  size_t expectedSize = 0;
  size_t receivedSize = 0;
  uint8_t expectedSha256[32] = {0};
  String error;
  mbedtls_sha256_context shaCtx;
};

OtaUpdateState otaUpdateState;

struct OtaPersistState {
  uint32_t bootCount = 0;
  String lastStatus;
  String lastSha256;
  String lastError;
  String lastAttemptAt;
};

OtaPersistState otaPersistState;
BLEScan *bleScan = nullptr;
BLEClient *activeBleClient = nullptr;
String activeBleAddress;
BLERemoteService *activeBleService = nullptr;
BLERemoteCharacteristic *activeCmdChar = nullptr;
BLERemoteCharacteristic *activeStatusChar = nullptr;
BLERemoteCharacteristic *activeNameChar = nullptr;
std::string lastStatusNotification;
unsigned long lastStatusNotificationAtMs = 0;
int lastJsonBodyErrorStatus = 400;
String lastJsonBodyError = "invalid json";

bool useSimulatedBackend() {
  return BEDJET_SIMULATED_BACKEND == 1;
}

RgbColor makeRgbColor(uint8_t red, uint8_t green, uint8_t blue) {
  RgbColor color;
  color.red = red;
  color.green = green;
  color.blue = blue;
  return color;
}

int clampSmartThingsPollIntervalSeconds(int value) {
  if (value < kMinSmartThingsPollIntervalSeconds) {
    return kMinSmartThingsPollIntervalSeconds;
  }
  if (value > kMaxSmartThingsPollIntervalSeconds) {
    return kMaxSmartThingsPollIntervalSeconds;
  }
  return value;
}

String simulatedDeviceIdForSide(const String &side) {
  return side == "left" ? "bedjet-3-left-demo" : "bedjet-3-right-demo";
}

String simulatedDeviceNameForSide(const String &side) {
  return side == "left" ? "BedJet 3 Left Demo" : "BedJet 3 Right Demo";
}

void writeJsonResponse(int statusCode, JsonDocument &doc) {
  String payload;
  serializeJson(doc, payload);
  server.send(statusCode, "application/json", payload);
}

void loadSlot(PairSlot &slot, const String &side) {
  slot.side = side;
  const String prefix = side + ".";
  slot.paired = preferences.getBool((prefix + "paired").c_str(), false);
  slot.deviceId = preferences.getString((prefix + "deviceId").c_str(), "");
  slot.displayName = preferences.getString((prefix + "displayName").c_str(), "");
  slot.pairedAt = preferences.getString((prefix + "pairedAt").c_str(), "");
}

void saveSlot(const PairSlot &slot) {
  const String prefix = slot.side + ".";
  preferences.putBool((prefix + "paired").c_str(), slot.paired);
  preferences.putString((prefix + "deviceId").c_str(), slot.deviceId);
  preferences.putString((prefix + "displayName").c_str(), slot.displayName);
  preferences.putString((prefix + "pairedAt").c_str(), slot.pairedAt);
}

void loadAuthState() {
  authState.claimed = preferences.getBool("auth.claimed", false);
  authState.gatewayId = preferences.getString("auth.gatewayId", "");
  authState.sharedSecret = preferences.getString("auth.secret", "");
  authState.claimedAt = preferences.getString("auth.claimedAt", "");
}

void saveAuthState() {
  preferences.putBool("auth.claimed", authState.claimed);
  preferences.putString("auth.gatewayId", authState.gatewayId);
  preferences.putString("auth.secret", authState.sharedSecret);
  preferences.putString("auth.claimedAt", authState.claimedAt);
}

void loadWiFiConfig() {
  wifiConfig.ssid = preferences.getString("wifi.ssid", "");
  wifiConfig.password = preferences.getString("wifi.password", "");
  wifiConfig.hostname = preferences.getString("wifi.hostname", "");
}

void saveWiFiConfig() {
  preferences.putString("wifi.ssid", wifiConfig.ssid);
  preferences.putString("wifi.password", wifiConfig.password);
  preferences.putString("wifi.hostname", wifiConfig.hostname);
}

void loadActivityLightConfig() {
  activityLightConfig.enabled = preferences.getBool("ui.activityLed", true);
}

void saveActivityLightConfig() {
  preferences.putBool("ui.activityLed", activityLightConfig.enabled);
}

void loadSmartThingsConfig() {
  const int configured = preferences.getInt("st.pollSec", kDefaultSmartThingsPollIntervalSeconds);
  smartthingsPollIntervalSeconds = clampSmartThingsPollIntervalSeconds(configured);
}

void saveSmartThingsConfig() {
  preferences.putInt("st.pollSec", smartthingsPollIntervalSeconds);
}

void loadOtaPersistState() {
  otaPersistState.bootCount = preferences.getULong("ota.bootCount", 0);
  otaPersistState.lastStatus = preferences.getString("ota.lastStatus", "");
  otaPersistState.lastSha256 = preferences.getString("ota.lastSha", "");
  otaPersistState.lastError = preferences.getString("ota.lastErr", "");
  otaPersistState.lastAttemptAt = preferences.getString("ota.lastAt", "");
}

void saveOtaPersistState() {
  preferences.putULong("ota.bootCount", otaPersistState.bootCount);
  preferences.putString("ota.lastStatus", otaPersistState.lastStatus);
  preferences.putString("ota.lastSha", otaPersistState.lastSha256);
  preferences.putString("ota.lastErr", otaPersistState.lastError);
  preferences.putString("ota.lastAt", otaPersistState.lastAttemptAt);
}

void writeActivityLightRaw(const RgbColor &color) {
  if (!kActivityLightAvailable) {
    return;
  }
  neopixelWrite(kActivityLightPin, color.red, color.green, color.blue);
}

void clearActivityLight() {
  activityLightPulse.active = false;
  writeActivityLightRaw(makeRgbColor(0, 0, 0));
}

void signalActivityLight(const RgbColor &color, unsigned long durationMs = 900) {
  if (!activityLightConfig.enabled || !kActivityLightAvailable) {
    return;
  }
  activityLightPulse.active = true;
  activityLightPulse.color = color;
  activityLightPulse.startedAtMs = millis();
  activityLightPulse.durationMs = durationMs;
}

void tickActivityLight() {
  if (!kActivityLightAvailable) {
    return;
  }

  if (!activityLightConfig.enabled) {
    writeActivityLightRaw(makeRgbColor(0, 0, 0));
    activityLightPulse.active = false;
    return;
  }

  if (!activityLightPulse.active) {
    return;
  }

  const unsigned long elapsed = millis() - activityLightPulse.startedAtMs;
  if (elapsed >= activityLightPulse.durationMs) {
    clearActivityLight();
    return;
  }

  const unsigned long riseMs = activityLightPulse.durationMs / 3;
  const unsigned long fadeMs = activityLightPulse.durationMs - riseMs;
  long brightness = 0;

  if (elapsed <= riseMs) {
    brightness = map(static_cast<long>(elapsed), 0L, static_cast<long>(riseMs == 0 ? 1 : riseMs), 10L, 84L);
  } else {
    const unsigned long fadeElapsed = elapsed - riseMs;
    brightness = map(static_cast<long>(fadeElapsed), 0L, static_cast<long>(fadeMs == 0 ? 1 : fadeMs), 84L, 0L);
  }

  RgbColor scaled = makeRgbColor(
      static_cast<uint8_t>((static_cast<uint16_t>(activityLightPulse.color.red) * brightness) / 255),
      static_cast<uint8_t>((static_cast<uint16_t>(activityLightPulse.color.green) * brightness) / 255),
      static_cast<uint8_t>((static_cast<uint16_t>(activityLightPulse.color.blue) * brightness) / 255));
  writeActivityLightRaw(scaled);
}

RgbColor colorForCommandActivity(const SideStatus &before, const SideStatus &after, const JsonDocument &body) {
  if (after.power.equalsIgnoreCase("off")) {
    return makeRgbColor(255, 132, 0);
  }

  if (body["targetTemperatureC"].is<int>()) {
    if (after.targetTemperatureC > before.targetTemperatureC) {
      return makeRgbColor(255, 48, 0);
    }
    if (after.targetTemperatureC < before.targetTemperatureC) {
      return makeRgbColor(0, 96, 255);
    }
  }

  if (body["fanStep"].is<int>()) {
    if (after.fanStep > before.fanStep) {
      return makeRgbColor(255, 60, 0);
    }
    if (after.fanStep < before.fanStep) {
      return makeRgbColor(0, 128, 255);
    }
  }

  if (after.mode.equalsIgnoreCase("heat") || after.mode.equalsIgnoreCase("extheat")) {
    return makeRgbColor(255, 40, 0);
  }
  if (after.mode.equalsIgnoreCase("cool") || after.mode.equalsIgnoreCase("dry")) {
    return makeRgbColor(0, 96, 255);
  }
  if (after.mode.equalsIgnoreCase("turbo")) {
    return makeRgbColor(180, 120, 255);
  }
  if (after.power.equalsIgnoreCase("on")) {
    return makeRgbColor(170, 170, 170);
  }

  return makeRgbColor(180, 180, 180);
}

String effectiveHostname() {
  if (wifiConfig.hostname.length() > 0) {
    return wifiConfig.hostname;
  }
  return String(MDNS_HOSTNAME);
}

String effectiveSsid() {
  if (wifiConfig.ssid.length() > 0) {
    return wifiConfig.ssid;
  }
  return String(WIFI_SSID);
}

String effectivePassword() {
  if (wifiConfig.password.length() > 0) {
    return wifiConfig.password;
  }
  return String(WIFI_PASSWORD);
}

bool isStationConnected() {
  return WiFi.status() == WL_CONNECTED;
}

bool isSetupApActive() {
  wifi_mode_t mode = WiFi.getMode();
  return mode == WIFI_AP || mode == WIFI_AP_STA;
}

String stationIp() {
  return isStationConnected() ? WiFi.localIP().toString() : String("");
}

String apIp() {
  return isSetupApActive() ? WiFi.softAPIP().toString() : String("");
}

String networkMode() {
  if (isStationConnected()) {
    return "station";
  }
  if (isSetupApActive()) {
    return "setup-ap";
  }
  return "offline";
}

String normalizeDeviceName(const String &value) {
  const String trimmed = value;
  if (trimmed.length() > 0) {
    return trimmed;
  }
  return String("BedJet");
}

bool isLikelyBedJetAdvertised(BLEAdvertisedDevice &device) {
  if (device.haveServiceUUID() && device.isAdvertisingService(BLEUUID(kBedJetServiceUuid))) {
    return true;
  }

  String name;
  if (device.haveName()) {
    name = String(device.getName().c_str());
  }
  name.toUpperCase();
  return name.indexOf("BEDJET") >= 0;
}

void handleStatusNotify(BLERemoteCharacteristic *characteristic, uint8_t *data, size_t length, bool isNotify) {
  (void)characteristic;
  (void)isNotify;
  if (data == nullptr || length == 0) {
    return;
  }
  lastStatusNotification.assign(reinterpret_cast<const char *>(data), length);
  lastStatusNotificationAtMs = millis();
}

void disconnectActiveBleClient() {
  if (activeBleClient != nullptr && activeBleClient->isConnected()) {
    activeBleClient->disconnect();
  }
  activeBleAddress = "";
  activeBleService = nullptr;
  activeCmdChar = nullptr;
  activeStatusChar = nullptr;
  activeNameChar = nullptr;
  lastStatusNotification.clear();
  lastStatusNotificationAtMs = 0;
}

bool ensureBleClientConnected(const String &deviceId, String &error) {
  if (useSimulatedBackend()) {
    return true;
  }

  if (activeBleClient != nullptr && activeBleClient->isConnected() && activeBleAddress == deviceId &&
      activeCmdChar != nullptr) {
    return true;
  }

  disconnectActiveBleClient();

  if (activeBleClient == nullptr) {
    activeBleClient = BLEDevice::createClient();
  }

  BLEAddress address(deviceId.c_str());
  if (!activeBleClient->connect(address)) {
    error = "failed to connect to BedJet over BLE";
    disconnectActiveBleClient();
    return false;
  }

  activeBleService = activeBleClient->getService(BLEUUID(kBedJetServiceUuid));
  if (activeBleService == nullptr) {
    error = "BedJet BLE service not found";
    disconnectActiveBleClient();
    return false;
  }

  activeCmdChar = activeBleService->getCharacteristic(BLEUUID(kBedJetCommandUuid));
  activeStatusChar = activeBleService->getCharacteristic(BLEUUID(kBedJetStatusUuid));
  activeNameChar = activeBleService->getCharacteristic(BLEUUID(kBedJetNameUuid));

  if (activeCmdChar == nullptr) {
    error = "BedJet command characteristic not found";
    disconnectActiveBleClient();
    return false;
  }

  if (activeStatusChar != nullptr && activeStatusChar->canNotify()) {
    activeStatusChar->registerForNotify(handleStatusNotify, true);
  }

  activeBleAddress = deviceId;
  return true;
}

bool writeBedJetPacket(uint8_t *data, size_t length, String &error) {
  if (useSimulatedBackend()) {
    return true;
  }

  if (activeCmdChar == nullptr) {
    error = "BedJet command characteristic unavailable";
    return false;
  }

  activeCmdChar->writeValue(data, length, false);
  delay(120);
  return true;
}

bool sendBedJetButton(const String &deviceId, uint8_t button, String &error) {
  if (!ensureBleClientConnected(deviceId, error)) {
    return false;
  }
  uint8_t packet[] = {CMD_BUTTON, button};
  return writeBedJetPacket(packet, sizeof(packet), error);
}

bool sendBedJetFan(const String &deviceId, int fanStep, String &error) {
  if (!ensureBleClientConnected(deviceId, error)) {
    return false;
  }
  int normalized = fanStep;
  if (normalized < 0) {
    normalized = 0;
  }
  if (normalized > 19) {
    normalized = normalized > 0 ? normalized - 1 : 19;
  }
  if (normalized > 19) {
    normalized = 19;
  }
  uint8_t packet[] = {CMD_SET_FAN, static_cast<uint8_t>(normalized)};
  return writeBedJetPacket(packet, sizeof(packet), error);
}

bool sendBedJetTemperature(const String &deviceId, int targetTemperatureC, String &error) {
  if (!ensureBleClientConnected(deviceId, error)) {
    return false;
  }
  int halfDegrees = targetTemperatureC * 2;
  if (halfDegrees < 0) {
    halfDegrees = 0;
  }
  if (halfDegrees > 255) {
    halfDegrees = 255;
  }
  uint8_t packet[] = {CMD_SET_TEMP, static_cast<uint8_t>(halfDegrees)};
  return writeBedJetPacket(packet, sizeof(packet), error);
}

int normalizeFanStep(int fanStep) {
  int normalized = fanStep;
  if (normalized < 0) {
    normalized = 0;
  }
  if (normalized > 19) {
    normalized = normalized > 0 ? normalized - 1 : 19;
  }
  if (normalized > 19) {
    normalized = 19;
  }
  return normalized;
}

String normalizeMode(const String &mode) {
  if (mode.equalsIgnoreCase("heat")) {
    return "heat";
  }
  if (mode.equalsIgnoreCase("turbo")) {
    return "turbo";
  }
  if (mode.equalsIgnoreCase("dry")) {
    return "dry";
  }
  if (mode.equalsIgnoreCase("extheat") || mode.equalsIgnoreCase("extht")) {
    return "extheat";
  }
  if (mode.equalsIgnoreCase("off")) {
    return "off";
  }
  return "cool";
}

String modeFromBedJetByte(uint8_t modeByte) {
  if (modeByte == 0 || modeByte == 6) {
    return "off";
  }
  if (modeByte == 1) {
    return "heat";
  }
  if (modeByte == 2) {
    return "turbo";
  }
  if (modeByte == 3) {
    return "extheat";
  }
  if (modeByte == 5) {
    return "dry";
  }
  return "cool";
}

String bytesToHexString(const uint8_t *data, size_t length) {
  static const char *hex = "0123456789abcdef";
  String out;
  out.reserve(length * 2);
  for (size_t i = 0; i < length; ++i) {
    out += hex[(data[i] >> 4) & 0x0f];
    out += hex[data[i] & 0x0f];
  }
  return out;
}

bool parseSha256Hex(const String &hex, uint8_t output[32]) {
  if (hex.length() != 64) {
    return false;
  }

  auto nibble = [](char c) -> int {
    if (c >= '0' && c <= '9') {
      return c - '0';
    }
    if (c >= 'a' && c <= 'f') {
      return c - 'a' + 10;
    }
    if (c >= 'A' && c <= 'F') {
      return c - 'A' + 10;
    }
    return -1;
  };

  for (size_t i = 0; i < 32; ++i) {
    const int hi = nibble(hex[i * 2]);
    const int lo = nibble(hex[(i * 2) + 1]);
    if (hi < 0 || lo < 0) {
      return false;
    }
    output[i] = static_cast<uint8_t>((hi << 4) | lo);
  }
  return true;
}

bool parseBedJetStatusPacket(const std::string &raw, ParsedBedJetStatus &parsed, String &error) {
  if (raw.empty()) {
    error = "empty BedJet status payload";
    return false;
  }

  const uint8_t *data = reinterpret_cast<const uint8_t *>(raw.data());
  const size_t length = raw.size();
  if (length == 11 && data[0] == 0x01) {
    // Compact ACK packet observed on BedJet V3 status characteristic.
    parsed.valid = true;
    parsed.partial = true;
    parsed.ackOnly = true;
    return true;
  }
  if (length < 11) {
    error = "BedJet status packet too short";
    return false;
  }

  if (data[1] != 0x56 || data[3] != 0x1) {
    error = String("BedJet status packet format mismatch: len=") + length + " hex=" + bytesToHexString(data, length);
    return false;
  }

  const uint8_t targetTempStep = data[8];
  const uint8_t modeByte = data[9];
  const uint8_t fanStep = data[10];
  const uint8_t ambientStep = length > 17 ? data[17] : data[7];

  if (modeByte >= 7 || targetTempStep < 38 || targetTempStep > 86 || ambientStep <= 1 || ambientStep > 100) {
    error = String("BedJet status packet failed sanity check: len=") + length + " hex=" + bytesToHexString(data, length);
    return false;
  }

  parsed.partial = data[0] != 0;
  parsed.mode = modeFromBedJetByte(modeByte);
  parsed.power = parsed.mode == "off" ? "off" : "on";
  parsed.fanStep = fanStep;
  parsed.targetTemperatureC = static_cast<int>(targetTempStep) / 2;
  parsed.currentTemperatureC = static_cast<int>(ambientStep) / 2;
  parsed.valid = true;
  return true;
}

bool readBedJetStatus(const String &deviceId, ParsedBedJetStatus &parsed, String &error) {
  if (!ensureBleClientConnected(deviceId, error)) {
    return false;
  }

  if (!lastStatusNotification.empty() && (millis() - lastStatusNotificationAtMs) < 4000) {
    String notifyError;
    if (parseBedJetStatusPacket(lastStatusNotification, parsed, notifyError)) {
      return true;
    }
  }

  if (activeStatusChar == nullptr || !activeStatusChar->canRead()) {
    error = "BedJet status characteristic unavailable";
    return false;
  }
  const std::string raw = activeStatusChar->readValue();
  return parseBedJetStatusPacket(raw, parsed, error);
}

bool commandFieldsMatch(const JsonDocument &body, const SideStatus &desired, const ParsedBedJetStatus &observed) {
  if (observed.ackOnly) {
    return false;
  }
  if (body["power"].is<const char *>()) {
    if (observed.power != desired.power) {
      return false;
    }
  }
  if (body["mode"].is<const char *>()) {
    if (observed.mode != desired.mode) {
      return false;
    }
  }
  if (body["fanStep"].is<int>()) {
    if (observed.fanStep != desired.fanStep) {
      return false;
    }
  }
  if (body["targetTemperatureC"].is<int>()) {
    if (observed.targetTemperatureC != desired.targetTemperatureC) {
      return false;
    }
  }
  return true;
}

bool confirmCommandApplied(SideState &state, const JsonDocument &body, const SideStatus &desired, String &error) {
  const unsigned long deadline = millis() + 2200;
  String lastError;
  bool ackSeen = false;

  while (millis() < deadline) {
    ParsedBedJetStatus observed;
    String readError;
    if (readBedJetStatus(state.slot.deviceId, observed, readError) && observed.valid) {
      if (observed.ackOnly) {
        ackSeen = true;
        lastError = "command acknowledged; awaiting state confirmation";
        delay(160);
        continue;
      }
      if (commandFieldsMatch(body, desired, observed)) {
        state.status.power = observed.power;
        state.status.mode = observed.mode;
        state.status.fanStep = observed.fanStep;
        state.status.targetTemperatureC = observed.targetTemperatureC;
        state.status.currentTemperatureC = observed.currentTemperatureC;
        state.status.bleReleased = false;
        return true;
      }
      lastError = "BedJet status mismatch while awaiting command ACK";
    } else if (readError.length() > 0) {
      lastError = readError;
    }
    delay(160);
  }

  if (lastError.length() == 0) {
    lastError = "command timed out waiting for BedJet state confirmation";
  } else if (ackSeen) {
    lastError = "command acknowledged but state confirmation timed out";
  }
  error = lastError;
  return false;
}

uint8_t buttonForMode(const String &mode) {
  if (mode.equalsIgnoreCase("heat")) {
    return BTN_HEAT;
  }
  if (mode.equalsIgnoreCase("turbo")) {
    return BTN_TURBO;
  }
  if (mode.equalsIgnoreCase("dry")) {
    return BTN_DRY;
  }
  if (mode.equalsIgnoreCase("extheat")) {
    return BTN_EXTHT;
  }
  if (mode.equalsIgnoreCase("off")) {
    return BTN_OFF;
  }
  return BTN_COOL;
}

bool applyModeOrPower(SideState &state, const JsonDocument &body, String &error) {
  if (useSimulatedBackend()) {
    return true;
  }

  const String deviceId = state.slot.deviceId;
  if (deviceId.length() == 0) {
    error = "no paired device id";
    return false;
  }

  bool sent = false;
  if (body["power"].is<const char *>()) {
    const String power = body["power"].as<const char *>();
    if (power.equalsIgnoreCase("off")) {
      sent = sendBedJetButton(deviceId, BTN_OFF, error);
      if (!sent) {
        return false;
      }
    } else if (power.equalsIgnoreCase("on") && !body["mode"].is<const char *>()) {
      String currentMode = state.status.mode.length() > 0 ? state.status.mode : String("cool");
      if (currentMode.equalsIgnoreCase("off")) {
        currentMode = "cool";
      }
      sent = sendBedJetButton(deviceId, buttonForMode(currentMode), error);
      if (!sent) {
        return false;
      }
    }
  }

  if (body["mode"].is<const char *>()) {
    const String mode = body["mode"].as<const char *>();
    uint8_t button = buttonForMode(mode);
    sent = sendBedJetButton(deviceId, button, error);
    if (!sent) {
      return false;
    }
  }

  return true;
}

std::vector<ScanCandidate> performBedJetScan() {
  std::vector<ScanCandidate> results;
  if (useSimulatedBackend()) {
    for (const char *side : {"left", "right"}) {
      ScanCandidate candidate;
      candidate.deviceId = simulatedDeviceIdForSide(side);
      candidate.displayName = simulatedDeviceNameForSide(side);
      candidate.rssi = String(side) == "left" ? -43 : -47;
      results.push_back(candidate);
    }
    return results;
  }

  BLEScanResults found = bleScan->start(4, false);
  const int count = found.getCount();
  for (int index = 0; index < count; ++index) {
    BLEAdvertisedDevice device = found.getDevice(index);
    if (!isLikelyBedJetAdvertised(device)) {
      continue;
    }

    ScanCandidate candidate;
    candidate.deviceId = String(device.getAddress().toString().c_str());
    candidate.displayName =
        device.haveName() ? String(device.getName().c_str()) : String("BedJet ") + candidate.deviceId;
    candidate.rssi = device.getRSSI();

    bool duplicate = false;
    for (const ScanCandidate &existing : results) {
      if (existing.deviceId == candidate.deviceId) {
        duplicate = true;
        break;
      }
    }
    if (!duplicate) {
      results.push_back(candidate);
    }
  }
  bleScan->clearResults();
  return results;
}

void scheduleRestart() {
  restartScheduled = true;
  restartAtMs = millis() + 1200;
}

String makeNonce() {
  char buffer[25];
  snprintf(buffer, sizeof(buffer), "%08lx%08lx%08lx", static_cast<unsigned long>(esp_random()),
           static_cast<unsigned long>(esp_random()), static_cast<unsigned long>(esp_random()));
  return String(buffer);
}

String hmacHex(const String &secret, const String &message) {
  unsigned char digest[32];
  const mbedtls_md_info_t *info = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
  mbedtls_md_hmac(info, reinterpret_cast<const unsigned char *>(secret.c_str()), secret.length(),
                  reinterpret_cast<const unsigned char *>(message.c_str()), message.length(), digest);

  char hex[65];
  for (size_t i = 0; i < sizeof(digest); ++i) {
    snprintf(hex + (i * 2), 3, "%02x", digest[i]);
  }
  hex[64] = '\0';
  return String(hex);
}

bool nonceSeen(const String &nonce) {
  for (size_t index = 0; index < kNonceCacheSize; ++index) {
    if (authState.recentNonces[index] == nonce) {
      return true;
    }
  }
  return false;
}

void rememberNonce(const String &nonce) {
  authState.recentNonces[authState.nonceIndex % kNonceCacheSize] = nonce;
  authState.nonceIndex = (authState.nonceIndex + 1) % kNonceCacheSize;
}

SideState &sideState(const String &side) {
  return side == "left" ? leftState : rightState;
}

bool parseJsonBody(JsonDocument &doc) {
  lastJsonBodyErrorStatus = 400;
  lastJsonBodyError = "invalid json";
  if (!server.hasArg("plain")) {
    lastJsonBodyError = "missing json body";
    return false;
  }
  const String body = server.arg("plain");
  if (body.length() > kMaxJsonBodyBytes) {
    lastJsonBodyErrorStatus = 413;
    lastJsonBodyError = String("json body exceeds ") + String(kMaxJsonBodyBytes) + " bytes";
    return false;
  }
  const DeserializationError error = deserializeJson(doc, body);
  return !error;
}

void sendJsonBodyError() {
  server.send(lastJsonBodyErrorStatus, "application/json", String("{\"error\":\"") + lastJsonBodyError + "\"}");
}

void addSlot(JsonObject object, const PairSlot &slot, const SideStatus &status) {
  object["paired"] = slot.paired;
  if (slot.paired) {
    object["deviceId"] = slot.deviceId;
    object["displayName"] = slot.displayName;
    object["pairedAt"] = slot.pairedAt;
  }
  JsonObject statusObject = object["status"].to<JsonObject>();
  statusObject["power"] = status.power;
  statusObject["mode"] = status.mode;
  statusObject["fanStep"] = status.fanStep;
  statusObject["targetTemperatureC"] = status.targetTemperatureC;
  statusObject["currentTemperatureC"] = status.currentTemperatureC;
  statusObject["bleReleased"] = status.bleReleased;
}

void addNetworkState(JsonObject object) {
  object["mode"] = networkMode();
  object["hostname"] = effectiveHostname();
  object["configuredSsid"] = effectiveSsid();
  object["stationConnected"] = isStationConnected();
  object["stationIp"] = stationIp();
  object["setupApActive"] = isSetupApActive();
  object["setupApSsid"] = isSetupApActive() ? String(kSetupApSsid) : String("");
  object["setupApIp"] = apIp();
  object["mdnsUrl"] = isStationConnected() ? "http://" + effectiveHostname() + ".local" : String("");
}

void addFirmwareInfo(JsonObject object) {
  object["apiVersion"] = kFirmwareApiVersion;
  object["buildId"] = kFirmwareBuildId;
  object["sketchMd5"] = ESP.getSketchMD5();
  object["bootCount"] = otaPersistState.bootCount;
  object["canRollback"] = Update.canRollBack();
  JsonObject ota = object["ota"].to<JsonObject>();
  ota["lastStatus"] = otaPersistState.lastStatus;
  ota["lastSha256"] = otaPersistState.lastSha256;
  ota["lastError"] = otaPersistState.lastError;
  ota["lastAttemptAt"] = otaPersistState.lastAttemptAt;
}

void addSmartThingsConfig(JsonObject object) {
  object["pollIntervalSeconds"] = smartthingsPollIntervalSeconds;
}

void addIndicatorConfig(JsonObject object) {
  object["activityLightEnabled"] = activityLightConfig.enabled;
  object["activityLightAvailable"] = kActivityLightAvailable;
}

bool isClaimRoute() {
  return server.uri() == "/api/v1/claim/status" || server.uri() == "/api/v1/claim";
}

bool isProvisionRoute() {
  return server.uri() == "/" || server.uri() == "/api/v1/provision/status" || server.uri() == "/api/v1/provision/wifi";
}

bool isLocalAdminRoute() {
  return server.uri().startsWith("/api/v1/local/");
}

bool provisioningRequiresAuth() {
  return authState.claimed && isStationConnected();
}

bool requestRequiresAuth() {
  if (server.uri() == "/healthz" || server.uri() == "/api/v1/version") {
    return false;
  }
  if (isClaimRoute()) {
    return false;
  }
  if (isProvisionRoute()) {
    return false;
  }
  if (isLocalAdminRoute()) {
    return false;
  }
  return true;
}

bool verifyRequestAuth() {
  if (!authState.claimed || authState.sharedSecret.length() == 0) {
    server.send(503, "application/json", "{\"error\":\"gateway not claimed\"}");
    return false;
  }

  if (!server.hasHeader("X-Gateway-Id") || !server.hasHeader("X-Timestamp") ||
      !server.hasHeader("X-Nonce") || !server.hasHeader("X-Signature")) {
    server.send(401, "application/json", "{\"error\":\"missing auth headers\"}");
    return false;
  }

  const String gatewayId = server.header("X-Gateway-Id");
  const String timestamp = server.header("X-Timestamp");
  const String nonce = server.header("X-Nonce");
  const String signature = server.header("X-Signature");

  if (gatewayId != authState.gatewayId) {
    server.send(403, "application/json", "{\"error\":\"gateway id mismatch\"}");
    return false;
  }

  // The bridge signs requests with epoch milliseconds, but the gateway does not yet
  // maintain wall-clock time. For now, require the header to parse and be present,
  // and rely on nonce replay protection plus the shared-secret signature.
  const unsigned long timestampMs = strtoul(timestamp.c_str(), nullptr, 10);
  if (timestampMs == 0) {
    server.send(401, "application/json", "{\"error\":\"invalid timestamp\"}");
    return false;
  }

  if (nonce.length() < 8 || nonceSeen(nonce)) {
    server.send(409, "application/json", "{\"error\":\"nonce rejected\"}");
    return false;
  }

  String body = server.hasArg("plain") ? server.arg("plain") : "";
  if (body.length() == 0 && server.hasHeader("X-Firmware-SHA256")) {
    body = "sha256:" + server.header("X-Firmware-SHA256");
  }
  const String message = String(server.method() == HTTP_GET ? "GET" : "POST") + "\n" + server.uri() + "\n" + body + "\n" +
                         timestamp + "\n" + nonce;
  const String expected = hmacHex(authState.sharedSecret, message);
  if (!expected.equalsIgnoreCase(signature)) {
    server.send(403, "application/json", "{\"error\":\"invalid signature\"}");
    return false;
  }

  rememberNonce(nonce);
  return true;
}

void handleClaimStatus() {
  JsonDocument doc;
  doc["claimable"] = !authState.claimed;
  doc["claimed"] = authState.claimed;
  doc["gatewayId"] = authState.gatewayId;
  doc["claimedAt"] = authState.claimedAt;
  writeJsonResponse(200, doc);
}

void handleClaim() {
  if (authState.claimed) {
    server.send(409, "application/json", "{\"error\":\"gateway already claimed\"}");
    return;
  }

  JsonDocument body;
  if (!parseJsonBody(body)) {
    sendJsonBodyError();
    return;
  }

  const String gatewayId = body["gatewayId"] | "";
  const String sharedSecret = body["sharedSecret"] | "";
  if (gatewayId.length() < 4 || sharedSecret.length() < 16) {
    server.send(400, "application/json", "{\"error\":\"gatewayId or sharedSecret too short\"}");
    return;
  }

  authState.claimed = true;
  authState.gatewayId = gatewayId;
  authState.sharedSecret = sharedSecret;
  authState.claimedAt = String(millis());
  saveAuthState();

  JsonDocument doc;
  doc["ok"] = true;
  doc["claimable"] = false;
  doc["claimed"] = true;
  doc["gatewayId"] = authState.gatewayId;
  doc["claimedAt"] = authState.claimedAt;
  writeJsonResponse(200, doc);
}

void handleProvisionStatus() {
  JsonDocument doc;
  doc["ok"] = true;
  JsonObject network = doc["network"].to<JsonObject>();
  addNetworkState(network);
  JsonObject claim = doc["claim"].to<JsonObject>();
  claim["claimed"] = authState.claimed;
  claim["gatewayId"] = authState.gatewayId;
  claim["claimedAt"] = authState.claimedAt;
  JsonObject provisioning = doc["provisioning"].to<JsonObject>();
  provisioning["authRequired"] = provisioningRequiresAuth();
  writeJsonResponse(200, doc);
}

void handleProvisionSave() {
  JsonDocument body;
  if (!parseJsonBody(body)) {
    sendJsonBodyError();
    return;
  }

  const String ssid = body["ssid"] | "";
  const String password = body["password"] | "";
  const String hostname = body["hostname"] | String(MDNS_HOSTNAME);

  if (ssid.length() < 1) {
    server.send(400, "application/json", "{\"error\":\"ssid is required\"}");
    return;
  }

  wifiConfig.ssid = ssid;
  wifiConfig.password = password;
  wifiConfig.hostname = hostname;
  saveWiFiConfig();

  JsonDocument doc;
  doc["ok"] = true;
  doc["saved"] = true;
  doc["restarting"] = true;
  doc["hostname"] = wifiConfig.hostname;
  doc["ssid"] = wifiConfig.ssid;
  writeJsonResponse(200, doc);
  scheduleRestart();
}

String buildProvisionPage() {
  String html = R"HTML(<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>BedJet Gateway Setup</title>
    <style>
      body { margin: 0; font-family: "Segoe UI", sans-serif; background: #f6f3ee; color: #1e2428; }
      main { max-width: 560px; margin: 0 auto; padding: 28px 18px 40px; }
      .card { background: white; border: 1px solid #ddd5ca; border-radius: 16px; padding: 20px; box-shadow: 0 16px 40px rgba(60,45,30,.08); }
      h1 { margin-top: 0; font-size: 1.8rem; }
      p { color: #58636b; }
      label { display: block; margin: 14px 0 6px; font-weight: 600; }
      input { width: 100%; box-sizing: border-box; padding: 12px 14px; border: 1px solid #d7cfc4; border-radius: 12px; font: inherit; }
      button { margin-top: 18px; width: 100%; padding: 12px 14px; border: 0; border-radius: 999px; background: #c4552f; color: white; font: inherit; font-weight: 700; }
      pre { background: #1f2328; color: #f1f5f9; padding: 12px; border-radius: 12px; overflow: auto; }
    </style>
  </head>
  <body>
    <main>
      <div class="card">
        <h1>BedJet Gateway Setup</h1>
        <p>Enter your Wi-Fi details. The gateway will reboot onto your normal network and advertise as <code>)HTML";
  html += effectiveHostname();
  html += R"HTML(.local</code>.</p>
        <form id="form">
          <label for="ssid">Wi-Fi name</label>
          <input id="ssid" name="ssid" required />
          <label for="password">Wi-Fi password</label>
          <input id="password" name="password" type="password" />
          <label for="hostname">Gateway hostname</label>
          <input id="hostname" name="hostname" value=")HTML";
  html += effectiveHostname();
  html += R"HTML(" />
          <button type="submit">Save and reboot</button>
        </form>
        <pre id="status">Loading...</pre>
      </div>
    <script>
      const statusNode = document.getElementById('status');
      const form = document.getElementById('form');

      async function refresh() {
        const response = await fetch('/api/v1/provision/status');
        const data = await response.json();
        statusNode.textContent = JSON.stringify(data, null, 2);
        document.getElementById('ssid').value = data.network.configuredSsid || '';
        document.getElementById('hostname').value = data.network.hostname || 'bedjet-gateway';
      }

      form.addEventListener('submit', async (event) => {
        event.preventDefault();
        const payload = {
          ssid: document.getElementById('ssid').value,
          password: document.getElementById('password').value,
          hostname: document.getElementById('hostname').value
        };
        const response = await fetch('/api/v1/provision/wifi', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(payload)
        });
        const data = await response.json();
        statusNode.textContent = JSON.stringify(data, null, 2);
      });

      refresh().catch((error) => {
        statusNode.textContent = error.message;
      });
    </script>
    </main>
  </body>
</html>)HTML";
  return html;
}

void handleProvisionPage() {
  server.send(200, "text/html; charset=utf-8", buildProvisionPage());
}

String buildGatewayPage() {
  String html = R"HTML(<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>BedJet Gateway</title>
    <style>
      :root {
        color-scheme: light;
        --bg: #f2efe9;
        --card: #ffffff;
        --border: #ddd5ca;
        --ink: #1d2428;
        --muted: #65717a;
        --accent: #bf522d;
        --accent-2: #23495c;
        --success: #1f7a53;
      }
      body { margin: 0; font-family: "Segoe UI", sans-serif; background: linear-gradient(180deg, #f5f1eb 0%, #ece6dc 100%); color: var(--ink); }
      main { max-width: 980px; margin: 0 auto; padding: 24px 16px 40px; }
      h1, h2, h3, p { margin-top: 0; }
      h1 { font-size: 2rem; margin-bottom: 8px; }
      p { color: var(--muted); }
      .grid { display: grid; gap: 16px; }
      .grid.two { grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); }
      .card { background: var(--card); border: 1px solid var(--border); border-radius: 18px; padding: 18px; box-shadow: 0 18px 48px rgba(44, 33, 18, .09); }
      .row { display: flex; flex-wrap: wrap; gap: 10px; align-items: center; }
      .pill { display: inline-flex; align-items: center; gap: 8px; padding: 8px 12px; border-radius: 999px; background: #f6f2eb; border: 1px solid var(--border); font-size: .92rem; }
      .dot { width: 10px; height: 10px; border-radius: 50%; background: #9aa8b1; }
      .dot.good { background: var(--success); }
      label { display: block; margin: 12px 0 6px; font-weight: 600; }
      input, select { width: 100%; box-sizing: border-box; padding: 12px 14px; border: 1px solid var(--border); border-radius: 12px; font: inherit; background: #fff; }
      input[type="checkbox"] { width: auto; padding: 0; }
      button { border: 0; border-radius: 999px; padding: 10px 14px; font: inherit; font-weight: 700; cursor: pointer; background: var(--accent); color: white; }
      button.secondary { background: var(--accent-2); }
      button.subtle { background: #eef2f4; color: var(--ink); }
      button.small { padding: 8px 12px; font-size: .92rem; }
      .devices, .pairing { display: grid; gap: 10px; }
      .device, .pairing-card { border: 1px solid var(--border); border-radius: 14px; padding: 12px; background: #fcfaf7; }
      .mono { font-family: ui-monospace, SFMono-Regular, Consolas, monospace; font-size: .9rem; }
      pre { margin: 0; background: #172026; color: #edf3f6; padding: 14px; border-radius: 14px; overflow: auto; max-height: 280px; }
      .section-head { display: flex; justify-content: space-between; align-items: center; gap: 12px; }
      .muted { color: var(--muted); }
      .toggle { display: flex; align-items: center; gap: 10px; margin-top: 12px; }
    </style>
  </head>
  <body>
    <main>
      <div class="card">
        <h1>BedJet Gateway</h1>
        <p>Use this page to provision Wi-Fi, scan for BedJets, manage left/right pairings, and run basic test commands directly from the ESP.</p>
        <div id="summary" class="row"></div>
      </div>

      <div class="grid two" style="margin-top: 16px;">
        <section class="card">
          <div class="section-head">
            <div>
              <h2>Gateway</h2>
              <p>Network, claim state, and runtime status.</p>
            </div>
            <button class="secondary small" id="refreshBtn">Refresh</button>
          </div>
          <pre id="status">Loading...</pre>
        </section>

        <section class="card">
          <h2>Wi-Fi</h2>
          <p>Update Wi-Fi credentials and hostname.</p>
          <p id="wifiNotice" class="muted"></p>
          <form id="wifiForm">
            <label for="ssid">Wi-Fi name</label>
            <input id="ssid" name="ssid" required />
            <label for="password">Wi-Fi password</label>
            <input id="password" name="password" type="password" />
            <label for="hostname">Gateway hostname</label>
            <input id="hostname" name="hostname" />
            <button type="submit">Save and reboot</button>
          </form>
          <hr style="margin: 16px 0; border: 0; border-top: 1px solid var(--border);" />
          <h3>SmartThings Sync</h3>
          <p>Control how often SmartThings re-reads real BedJet state.</p>
          <form id="smartthingsForm">
            <label for="pollIntervalSeconds">Poll interval seconds</label>
            <input id="pollIntervalSeconds" name="pollIntervalSeconds" type="number" min="5" max="120" value="15" required />
            <button class="secondary" type="submit">Save SmartThings Settings</button>
          </form>
          <hr style="margin: 16px 0; border: 0; border-top: 1px solid var(--border);" />
          <h3>Activity Light</h3>
          <p>Give the built-in RGB light a subtle pulse on confirmed actions. Cool or lower trends lean blue; warmer or higher trends lean red.</p>
          <form id="lightingForm">
            <label class="toggle" for="activityLightEnabled">
              <input id="activityLightEnabled" name="activityLightEnabled" type="checkbox" />
              <span>Enable activity light</span>
            </label>
            <button class="secondary" type="submit">Save Light Settings</button>
          </form>
        </section>
      </div>

      <div class="grid two" style="margin-top: 16px;">
        <section class="card">
          <div class="section-head">
            <div>
              <h2>Scan</h2>
              <p>Power on one BedJet at a time, then scan and assign it to Left or Right.</p>
            </div>
            <button id="scanBtn">Scan for BedJets</button>
          </div>
          <div id="devices" class="devices muted">No scan yet.</div>
        </section>

        <section class="card">
          <div class="section-head">
            <div>
              <h2>Pairings</h2>
              <p>Review and manage saved Left and Right assignments.</p>
            </div>
            <button class="subtle small" id="releaseAllBtn">Release BLE</button>
          </div>
          <div id="pairings" class="pairing muted">Loading...</div>
        </section>
      </div>

      <section class="card" style="margin-top: 16px;">
        <h2>Basic Test Controls</h2>
        <p>Use these after pairing to confirm each side responds.</p>
        <div class="grid two">
          <form class="controlForm" data-side="left">
            <h3>Left</h3>
            <label>Power</label>
            <select name="power"><option value="on">On</option><option value="off">Off</option></select>
            <label>Mode</label>
            <select name="mode"><option value="cool">Cool</option><option value="heat">Heat</option><option value="dry">Dry</option><option value="turbo">Turbo</option></select>
            <label>Fan Step</label>
            <input name="fanStep" type="number" min="1" max="20" value="8" />
            <label>Target Temperature C</label>
            <input name="targetTemperatureC" type="number" min="15" max="40" value="24" />
            <button type="submit">Send Left Command</button>
          </form>
          <form class="controlForm" data-side="right">
            <h3>Right</h3>
            <label>Power</label>
            <select name="power"><option value="on">On</option><option value="off">Off</option></select>
            <label>Mode</label>
            <select name="mode"><option value="cool">Cool</option><option value="heat">Heat</option><option value="dry">Dry</option><option value="turbo">Turbo</option></select>
            <label>Fan Step</label>
            <input name="fanStep" type="number" min="1" max="20" value="8" />
            <label>Target Temperature C</label>
            <input name="targetTemperatureC" type="number" min="15" max="40" value="24" />
            <button type="submit">Send Right Command</button>
          </form>
        </div>
      </section>
    </main>
    <script>
      const statusNode = document.getElementById('status');
      const summaryNode = document.getElementById('summary');
      const devicesNode = document.getElementById('devices');
      const pairingsNode = document.getElementById('pairings');
      const refreshBtn = document.getElementById('refreshBtn');
      const scanBtn = document.getElementById('scanBtn');
      const releaseAllBtn = document.getElementById('releaseAllBtn');
      const wifiForm = document.getElementById('wifiForm');
      const wifiNotice = document.getElementById('wifiNotice');
      const smartthingsForm = document.getElementById('smartthingsForm');
      const lightingForm = document.getElementById('lightingForm');
      let lastScan = [];

      function escapeHtml(value) {
        return String(value ?? '')
          .replaceAll('&', '&amp;')
          .replaceAll('<', '&lt;')
          .replaceAll('>', '&gt;')
          .replaceAll('"', '&quot;')
          .replaceAll("'", '&#39;');
      }

      function renderSummary(data) {
        const items = [];
        const networkGood = data.network?.stationConnected;
        const firmware = data.firmware || {};
        const apiVersion = firmware.apiVersion || 'n/a';
        const buildId = firmware.buildId || 'n/a';
        const pollIntervalSeconds = data.smartthings?.pollIntervalSeconds || 15;
        const activityLightAvailable = !!data.indicators?.activityLightAvailable;
        const activityLightEnabled = !!data.indicators?.activityLightEnabled;
        items.push(`<span class="pill"><span class="dot ${networkGood ? 'good' : ''}"></span>${networkGood ? 'On Wi-Fi' : 'Setup AP'}</span>`);
        items.push(`<span class="pill">Hostname: <span class="mono">${escapeHtml(data.network?.hostname || 'bedjet-gateway')}</span></span>`);
        items.push(`<span class="pill">Claimed: <strong>${data.claim?.claimed ? 'Yes' : 'No'}</strong></span>`);
        items.push(`<span class="pill">Backend: <strong>${data.simulatedBackend ? 'Simulated' : 'BLE'}</strong></span>`);
        items.push(`<span class="pill">Version: <span class="mono">v${escapeHtml(apiVersion)}</span> · Build: <span class="mono">${escapeHtml(buildId)}</span></span>`);
        items.push(`<span class="pill">SmartThings Poll: <span class="mono">${escapeHtml(pollIntervalSeconds)}s</span></span>`);
        items.push(`<span class="pill">Activity Light: <strong>${activityLightAvailable ? (activityLightEnabled ? 'On' : 'Off') : 'Unavailable'}</strong></span>`);
        summaryNode.innerHTML = items.join('');
      }

      function renderPairings(data) {
        const sides = data.sides || {};
        pairingsNode.innerHTML = ['left', 'right'].map((side) => {
          const entry = sides[side] || {};
          const paired = !!entry.paired;
          const status = entry.status || {};
          return `
            <div class="pairing-card">
              <div class="section-head">
                <strong>${side === 'left' ? 'Left' : 'Right'}</strong>
                <div class="row">
                  <button class="small secondary" data-action="verify" data-side="${side}">Verify</button>
                  <button class="small subtle" data-action="forget" data-side="${side}">Forget</button>
                  <button class="small subtle" data-action="release" data-side="${side}">Release</button>
                </div>
              </div>
              <p class="muted">${paired ? escapeHtml(entry.displayName || entry.deviceId) : 'Not paired yet.'}</p>
              <div class="mono">deviceId: ${escapeHtml(entry.deviceId || '-')}</div>
              <div class="mono">power=${escapeHtml(status.power || 'off')} mode=${escapeHtml(status.mode || 'cool')} fan=${escapeHtml(status.fanStep ?? '-')} temp=${escapeHtml(status.targetTemperatureC ?? '-')} bleReleased=${escapeHtml(status.bleReleased ?? false)}</div>
            </div>`;
        }).join('');
      }

      function renderDevices(devices) {
        if (!devices.length) {
          devicesNode.innerHTML = '<div class="muted">No BedJets found. Power on one unit and try again.</div>';
          return;
        }
        devicesNode.innerHTML = devices.map((device) => `
          <div class="device">
            <div class="section-head">
              <div>
                <strong>${escapeHtml(device.displayName || device.deviceId)}</strong>
                <div class="mono">${escapeHtml(device.deviceId || '')}</div>
              </div>
              <div class="row">
                <button class="small" data-action="pair" data-side="left" data-device-id="${escapeHtml(device.deviceId)}" data-display-name="${escapeHtml(device.displayName || '')}">Pair Left</button>
                <button class="small secondary" data-action="pair" data-side="right" data-device-id="${escapeHtml(device.deviceId)}" data-display-name="${escapeHtml(device.displayName || '')}">Pair Right</button>
              </div>
            </div>
            <div class="muted">RSSI: ${escapeHtml(device.rssi ?? '')}</div>
          </div>`).join('');
      }

      async function api(method, path, body) {
        const response = await fetch(path, {
          method,
          headers: body ? { 'Content-Type': 'application/json' } : {},
          body: body ? JSON.stringify(body) : undefined
        });
        const data = await response.json();
        if (!response.ok) {
          throw new Error(data.error || `${response.status}`);
        }
        return data;
      }

      async function refresh() {
        const data = await api('GET', '/api/v1/local/status');
        statusNode.textContent = JSON.stringify(data, null, 2);
        renderSummary(data);
        renderPairings(data);
        document.getElementById('ssid').value = data.network?.configuredSsid || '';
        document.getElementById('hostname').value = data.network?.hostname || 'bedjet-gateway';
        document.getElementById('pollIntervalSeconds').value = data.smartthings?.pollIntervalSeconds || 15;
        document.getElementById('activityLightEnabled').checked = !!data.indicators?.activityLightEnabled;
        for (const element of lightingForm.elements) {
          element.disabled = !data.indicators?.activityLightAvailable;
        }
        const wifiLocked = !!data.provisioning?.authRequired;
        for (const element of wifiForm.elements) {
          element.disabled = wifiLocked;
        }
        wifiNotice.textContent = wifiLocked
          ? 'Wi-Fi changes are locked on the LAN after claim. Use the signed remote Wi-Fi script or preseed Wi-Fi at flash time.'
          : 'Wi-Fi changes are available before claim or while the gateway is in setup AP mode.';
      }

      async function scan() {
        const data = await api('GET', '/api/v1/local/scan');
        lastScan = data.devices || [];
        renderDevices(lastScan);
      }

      async function sideAction(action, side, payload) {
        const result = await api('POST', `/api/v1/local/${action}/${side}`, payload);
        statusNode.textContent = JSON.stringify(result, null, 2);
        await refresh();
        return result;
      }

      refreshBtn.addEventListener('click', () => refresh().catch((error) => statusNode.textContent = error.message));
      scanBtn.addEventListener('click', () => scan().catch((error) => statusNode.textContent = error.message));
      releaseAllBtn.addEventListener('click', () => api('POST', '/api/v1/local/release-all').then(refresh).catch((error) => statusNode.textContent = error.message));

      wifiForm.addEventListener('submit', async (event) => {
        event.preventDefault();
        try {
          const result = await api('POST', '/api/v1/provision/wifi', {
            ssid: document.getElementById('ssid').value,
            password: document.getElementById('password').value,
            hostname: document.getElementById('hostname').value
          });
          statusNode.textContent = JSON.stringify(result, null, 2);
        } catch (error) {
          statusNode.textContent = error.message;
        }
      });

      smartthingsForm.addEventListener('submit', async (event) => {
        event.preventDefault();
        try {
          const result = await api('POST', '/api/v1/local/settings', {
            pollIntervalSeconds: Number(document.getElementById('pollIntervalSeconds').value)
          });
          statusNode.textContent = JSON.stringify(result, null, 2);
          await refresh();
        } catch (error) {
          statusNode.textContent = error.message;
        }
      });

      lightingForm.addEventListener('submit', async (event) => {
        event.preventDefault();
        try {
          const result = await api('POST', '/api/v1/local/settings', {
            activityLightEnabled: document.getElementById('activityLightEnabled').checked
          });
          statusNode.textContent = JSON.stringify(result, null, 2);
          await refresh();
        } catch (error) {
          statusNode.textContent = error.message;
        }
      });

      document.addEventListener('click', async (event) => {
        const button = event.target.closest('button[data-action]');
        if (!button) return;
        try {
          if (button.dataset.action === 'pair') {
            await sideAction('pair', button.dataset.side, {
              deviceId: button.dataset.deviceId,
              displayName: button.dataset.displayName
            });
            return;
          }
          await sideAction(button.dataset.action, button.dataset.side);
        } catch (error) {
          statusNode.textContent = error.message;
        }
      });

      for (const form of document.querySelectorAll('.controlForm')) {
        form.addEventListener('submit', async (event) => {
          event.preventDefault();
          const side = form.dataset.side;
          try {
            await sideAction('command', side, {
              power: form.power.value,
              mode: form.mode.value,
              fanStep: Number(form.fanStep.value),
              targetTemperatureC: Number(form.targetTemperatureC.value)
            });
          } catch (error) {
            statusNode.textContent = error.message;
          }
        });
      }

      refresh().catch((error) => statusNode.textContent = error.message);
    </script>
  </body>
</html>)HTML";
  return html;
}

void handleGatewayPage() {
  server.send(200, "text/html; charset=utf-8", buildGatewayPage());
}

void handleHealthz() {
  JsonDocument doc;
  doc["ok"] = true;
  doc["service"] = "bedjet-gateway";
  doc["simulatedBackend"] = BEDJET_SIMULATED_BACKEND == 1;
  doc["claimed"] = authState.claimed;
  doc["firmwareBuildId"] = kFirmwareBuildId;
  JsonObject network = doc["network"].to<JsonObject>();
  addNetworkState(network);
  writeJsonResponse(200, doc);
}

void handleVersion() {
  JsonDocument doc;
  doc["ok"] = true;
  doc["service"] = "bedjet-gateway";
  JsonObject firmware = doc["firmware"].to<JsonObject>();
  addFirmwareInfo(firmware);
  writeJsonResponse(200, doc);
}

void handleState() {
  JsonDocument doc;
  JsonObject claim = doc["claim"].to<JsonObject>();
  claim["claimed"] = authState.claimed;
  claim["gatewayId"] = authState.gatewayId;
  JsonObject network = doc["network"].to<JsonObject>();
  addNetworkState(network);
  JsonObject firmware = doc["firmware"].to<JsonObject>();
  addFirmwareInfo(firmware);
  JsonObject smartthings = doc["smartthings"].to<JsonObject>();
  addSmartThingsConfig(smartthings);
  JsonObject indicators = doc["indicators"].to<JsonObject>();
  addIndicatorConfig(indicators);
  JsonObject sides = doc["sides"].to<JsonObject>();
  addSlot(sides["left"].to<JsonObject>(), leftState.slot, leftState.status);
  addSlot(sides["right"].to<JsonObject>(), rightState.slot, rightState.status);
  writeJsonResponse(200, doc);
}

void handleLocalStatus() {
  JsonDocument doc;
  doc["ok"] = true;
  doc["simulatedBackend"] = BEDJET_SIMULATED_BACKEND == 1;
  JsonObject claim = doc["claim"].to<JsonObject>();
  claim["claimed"] = authState.claimed;
  claim["gatewayId"] = authState.gatewayId;
  claim["claimedAt"] = authState.claimedAt;
  JsonObject network = doc["network"].to<JsonObject>();
  addNetworkState(network);
  JsonObject firmware = doc["firmware"].to<JsonObject>();
  addFirmwareInfo(firmware);
  JsonObject smartthings = doc["smartthings"].to<JsonObject>();
  addSmartThingsConfig(smartthings);
  JsonObject indicators = doc["indicators"].to<JsonObject>();
  addIndicatorConfig(indicators);
  JsonObject provisioning = doc["provisioning"].to<JsonObject>();
  provisioning["authRequired"] = provisioningRequiresAuth();
  JsonObject sides = doc["sides"].to<JsonObject>();
  addSlot(sides["left"].to<JsonObject>(), leftState.slot, leftState.status);
  addSlot(sides["right"].to<JsonObject>(), rightState.slot, rightState.status);
  writeJsonResponse(200, doc);
}

void handleLocalSettings() {
  JsonDocument body;
  if (!parseJsonBody(body)) {
    sendJsonBodyError();
    return;
  }

  bool changed = false;
  const JsonVariant requestedPollInterval = body["pollIntervalSeconds"];
  if (!requestedPollInterval.isNull()) {
    const int configuredPollInterval = requestedPollInterval.as<int>();
    if (configuredPollInterval <= 0) {
      server.send(400, "application/json", "{\"error\":\"pollIntervalSeconds must be an integer\"}");
      return;
    }
    smartthingsPollIntervalSeconds = clampSmartThingsPollIntervalSeconds(configuredPollInterval);
    saveSmartThingsConfig();
    changed = true;
  }

  const JsonVariant requestedActivityLightEnabled = body["activityLightEnabled"];
  if (!requestedActivityLightEnabled.isNull()) {
    activityLightConfig.enabled = requestedActivityLightEnabled.as<bool>();
    saveActivityLightConfig();
    if (!activityLightConfig.enabled) {
      clearActivityLight();
    } else {
      signalActivityLight(makeRgbColor(180, 180, 180), 420);
    }
    changed = true;
  }

  if (!changed) {
    server.send(400, "application/json", "{\"error\":\"pollIntervalSeconds or activityLightEnabled is required\"}");
    return;
  }

  JsonDocument response;
  response["ok"] = true;
  JsonObject smartthings = response["smartthings"].to<JsonObject>();
  addSmartThingsConfig(smartthings);
  JsonObject indicators = response["indicators"].to<JsonObject>();
  addIndicatorConfig(indicators);
  writeJsonResponse(200, response);
}

void handleScan() {
  JsonDocument doc;
  JsonArray devices = doc["devices"].to<JsonArray>();
  for (const ScanCandidate &candidate : performBedJetScan()) {
    JsonObject device = devices.add<JsonObject>();
    device["deviceId"] = candidate.deviceId;
    device["displayName"] = candidate.displayName;
    device["rssi"] = candidate.rssi;
  }
  writeJsonResponse(200, doc);
}

bool parseSideFromUri(String &side, const String &prefix, const String &alternatePrefix = "") {
  const String uri = server.uri();
  if (uri.startsWith(prefix)) {
    side = uri.substring(prefix.length());
    return side == "left" || side == "right";
  }
  if (alternatePrefix.length() > 0 && uri.startsWith(alternatePrefix)) {
    side = uri.substring(alternatePrefix.length());
    return side == "left" || side == "right";
  }
  return false;
}

void handlePair() {
  String side;
  if (!parseSideFromUri(side, "/api/v1/pair/", "/api/v1/local/pair/")) {
    server.send(404, "application/json", "{\"error\":\"invalid side\"}");
    return;
  }

  JsonDocument body;
  if (!parseJsonBody(body)) {
    sendJsonBodyError();
    return;
  }

  SideState &state = sideState(side);
  state.slot.side = side;
  state.slot.paired = true;
  state.slot.deviceId = body["deviceId"] | "";
  state.slot.displayName = body["displayName"] | "";
  if (state.slot.deviceId.length() == 0) {
    server.send(400, "application/json", "{\"error\":\"deviceId is required\"}");
    return;
  }
  if (state.slot.displayName.length() == 0) {
    state.slot.displayName = String("BedJet ") + state.slot.deviceId;
  }
  state.slot.pairedAt = String(millis());
  state.status.bleReleased = false;
  saveSlot(state.slot);
  signalActivityLight(makeRgbColor(0, 220, 96), 720);

  JsonDocument response;
  response["ok"] = true;
  JsonObject pairing = response["pairing"].to<JsonObject>();
  pairing["side"] = side;
  pairing["deviceId"] = state.slot.deviceId;
  pairing["displayName"] = state.slot.displayName;
  pairing["pairedAt"] = state.slot.pairedAt;
  writeJsonResponse(200, response);
}

void handleVerify() {
  String side;
  if (!parseSideFromUri(side, "/api/v1/verify/", "/api/v1/local/verify/")) {
    server.send(404, "application/json", "{\"error\":\"invalid side\"}");
    return;
  }

  SideState &state = sideState(side);
  if (state.slot.paired && !useSimulatedBackend()) {
    String error;
    if (!ensureBleClientConnected(state.slot.deviceId, error)) {
      server.send(503, "application/json", String("{\"error\":\"") + error + "\"}");
      return;
    }
    if (activeNameChar != nullptr && activeNameChar->canRead()) {
      const std::string remoteName = activeNameChar->readValue();
      if (!remoteName.empty()) {
        state.slot.displayName = String(remoteName.c_str());
        saveSlot(state.slot);
      }
    }
  }
  JsonDocument response;
  response["ok"] = state.slot.paired;
  response["side"] = side;
  if (state.slot.paired) {
    JsonObject pairing = response["pairing"].to<JsonObject>();
    pairing["side"] = side;
    pairing["deviceId"] = state.slot.deviceId;
    pairing["displayName"] = state.slot.displayName;
    pairing["pairedAt"] = state.slot.pairedAt;
  }
  JsonObject status = response["status"].to<JsonObject>();
  status["power"] = state.status.power;
  status["mode"] = state.status.mode;
  status["fanStep"] = state.status.fanStep;
  status["targetTemperatureC"] = state.status.targetTemperatureC;
  status["currentTemperatureC"] = state.status.currentTemperatureC;
  status["bleReleased"] = state.status.bleReleased;
  if (state.slot.paired) {
    signalActivityLight(makeRgbColor(0, 220, 96), 520);
  }
  writeJsonResponse(200, response);
}

void handleForget() {
  String side;
  if (!parseSideFromUri(side, "/api/v1/forget/", "/api/v1/local/forget/")) {
    server.send(404, "application/json", "{\"error\":\"invalid side\"}");
    return;
  }

  SideState &state = sideState(side);
  state.slot = PairSlot{};
  state.slot.side = side;
  state.status = SideStatus{};
  saveSlot(state.slot);
  signalActivityLight(makeRgbColor(255, 132, 0), 520);

  JsonDocument response;
  response["ok"] = true;
  response["side"] = side;
  writeJsonResponse(200, response);
}

void handleRelease() {
  String side;
  if (!parseSideFromUri(side, "/api/v1/release/", "/api/v1/local/release/")) {
    server.send(404, "application/json", "{\"error\":\"invalid side\"}");
    return;
  }

  SideState &state = sideState(side);
  state.status.bleReleased = true;
  if (!useSimulatedBackend() && activeBleAddress == state.slot.deviceId) {
    disconnectActiveBleClient();
  }
  signalActivityLight(makeRgbColor(255, 132, 0), 520);

  JsonDocument response;
  response["ok"] = true;
  response["side"] = side;
  response["bleReleased"] = true;
  writeJsonResponse(200, response);
}

void handleReleaseAll() {
  leftState.status.bleReleased = true;
  rightState.status.bleReleased = true;
  if (!useSimulatedBackend()) {
    disconnectActiveBleClient();
  }
  signalActivityLight(makeRgbColor(255, 132, 0), 520);

  JsonDocument response;
  response["ok"] = true;
  writeJsonResponse(200, response);
}

void handleCommand() {
  String side;
  if (!parseSideFromUri(side, "/api/v1/command/", "/api/v1/local/command/")) {
    server.send(404, "application/json", "{\"error\":\"invalid side\"}");
    return;
  }

  SideState &state = sideState(side);
  const SideStatus before = state.status;
  if (!state.slot.paired) {
    server.send(409, "application/json", "{\"error\":\"side not paired\"}");
    return;
  }

  JsonDocument body;
  if (!parseJsonBody(body)) {
    sendJsonBodyError();
    return;
  }

  SideStatus desired = state.status;
  if (body["power"].is<const char *>()) {
    desired.power = body["power"].as<const char *>();
  }
  if (body["mode"].is<const char *>()) {
    desired.mode = normalizeMode(body["mode"].as<const char *>());
  }
  if (body["fanStep"].is<int>()) {
    desired.fanStep = normalizeFanStep(body["fanStep"].as<int>());
  }
  if (body["targetTemperatureC"].is<int>()) {
    desired.targetTemperatureC = body["targetTemperatureC"].as<int>();
  }

  if (!useSimulatedBackend()) {
    String error;
    if (!applyModeOrPower(state, body, error)) {
      server.send(503, "application/json", String("{\"error\":\"") + error + "\"}");
      return;
    }
    if (body["fanStep"].is<int>() && !sendBedJetFan(state.slot.deviceId, body["fanStep"].as<int>(), error)) {
      server.send(503, "application/json", String("{\"error\":\"") + error + "\"}");
      return;
    }
    if (body["targetTemperatureC"].is<int>() &&
        !sendBedJetTemperature(state.slot.deviceId, body["targetTemperatureC"].as<int>(), error)) {
      server.send(503, "application/json", String("{\"error\":\"") + error + "\"}");
      return;
    }

    if (!confirmCommandApplied(state, body, desired, error)) {
      server.send(504, "application/json", String("{\"error\":\"") + error + "\"}");
      return;
    }
  } else {
    state.status = desired;
  }

  state.status.bleReleased = false;
  signalActivityLight(colorForCommandActivity(before, state.status, body));

  JsonDocument response;
  response["ok"] = true;
  response["confirmed"] = true;
  response["side"] = side;
  JsonObject status = response["status"].to<JsonObject>();
  status["power"] = state.status.power;
  status["mode"] = state.status.mode;
  status["fanStep"] = state.status.fanStep;
  status["targetTemperatureC"] = state.status.targetTemperatureC;
  status["currentTemperatureC"] = state.status.currentTemperatureC;
  status["bleReleased"] = state.status.bleReleased;
  writeJsonResponse(200, response);
}

void resetOtaUpdateState() {
  if (otaUpdateState.active) {
    mbedtls_sha256_free(&otaUpdateState.shaCtx);
  }
  otaUpdateState = OtaUpdateState{};
}

void handleFirmwareUploadChunk() {
  HTTPUpload &upload = server.upload();
  switch (upload.status) {
    case UPLOAD_FILE_START: {
      resetOtaUpdateState();
      otaUpdateState.active = true;

      if (!verifyRequestAuth()) {
        otaUpdateState.error = "unauthorized firmware upload request";
        return;
      }

      if (!server.hasHeader("X-Firmware-SHA256")) {
        otaUpdateState.error = "missing X-Firmware-SHA256 header";
        return;
      }

      const String expectedHash = server.header("X-Firmware-SHA256");
      if (!parseSha256Hex(expectedHash, otaUpdateState.expectedSha256)) {
        otaUpdateState.error = "invalid X-Firmware-SHA256 format";
        return;
      }

      if (!Update.begin(UPDATE_SIZE_UNKNOWN, U_FLASH)) {
        otaUpdateState.error = String("Update begin failed: ") + Update.errorString();
        return;
      }

      otaUpdateState.expectedSize = upload.totalSize;
      otaUpdateState.started = true;
      mbedtls_sha256_init(&otaUpdateState.shaCtx);
      mbedtls_sha256_starts_ret(&otaUpdateState.shaCtx, 0);
      break;
    }
    case UPLOAD_FILE_WRITE: {
      if (!otaUpdateState.active || !otaUpdateState.started || otaUpdateState.error.length() > 0) {
        return;
      }
      if (upload.currentSize == 0) {
        return;
      }
      mbedtls_sha256_update_ret(&otaUpdateState.shaCtx, upload.buf, upload.currentSize);
      if (Update.write(upload.buf, upload.currentSize) != upload.currentSize) {
        otaUpdateState.error = String("firmware write failed: ") + Update.errorString();
        return;
      }
      otaUpdateState.receivedSize += upload.currentSize;
      break;
    }
    case UPLOAD_FILE_END: {
      if (!otaUpdateState.active || !otaUpdateState.started || otaUpdateState.error.length() > 0) {
        return;
      }

      uint8_t digest[32];
      mbedtls_sha256_finish_ret(&otaUpdateState.shaCtx, digest);
      mbedtls_sha256_free(&otaUpdateState.shaCtx);

      const String receivedHashHex = bytesToHexString(digest, sizeof(digest));
      const String expectedHashHex = bytesToHexString(otaUpdateState.expectedSha256, sizeof(otaUpdateState.expectedSha256));
      if (receivedHashHex != expectedHashHex) {
        Update.abort();
        otaUpdateState.error = String("firmware SHA256 mismatch expected=") + expectedHashHex + " received=" + receivedHashHex;
        return;
      }

      if (!Update.end(true)) {
        otaUpdateState.error = String("firmware finalize failed: ") + Update.errorString();
        return;
      }

      otaUpdateState.completed = true;
      otaUpdateState.ok = true;
      break;
    }
    case UPLOAD_FILE_ABORTED: {
      if (otaUpdateState.active && otaUpdateState.started) {
        Update.abort();
      }
      otaUpdateState.error = "firmware upload aborted";
      break;
    }
    default:
      break;
  }
}

void handleFirmwareUpdate() {
  JsonDocument response;
  response["ok"] = false;

  if (!otaUpdateState.active) {
    response["error"] = "no upload session";
    writeJsonResponse(400, response);
    return;
  }

  if (otaUpdateState.error.length() > 0) {
    response["error"] = otaUpdateState.error;
    otaPersistState.lastStatus = "failed";
    otaPersistState.lastError = otaUpdateState.error;
    otaPersistState.lastAttemptAt = String(millis());
    saveOtaPersistState();
    resetOtaUpdateState();
    writeJsonResponse(400, response);
    return;
  }

  if (!otaUpdateState.completed || !otaUpdateState.ok) {
    response["error"] = "firmware upload incomplete";
    otaPersistState.lastStatus = "failed";
    otaPersistState.lastError = "firmware upload incomplete";
    otaPersistState.lastAttemptAt = String(millis());
    saveOtaPersistState();
    resetOtaUpdateState();
    writeJsonResponse(400, response);
    return;
  }

  response["ok"] = true;
  response["applied"] = true;
  response["bytes"] = otaUpdateState.receivedSize;
  response["restarting"] = true;
  response["buildId"] = kFirmwareBuildId;
  otaPersistState.lastStatus = "applied-pending-reboot";
  otaPersistState.lastSha256 = bytesToHexString(otaUpdateState.expectedSha256, sizeof(otaUpdateState.expectedSha256));
  otaPersistState.lastError = "";
  otaPersistState.lastAttemptAt = String(millis());
  saveOtaPersistState();
  resetOtaUpdateState();
  scheduleRestart();
  writeJsonResponse(200, response);
}

void handleFirmwareRollback() {
  JsonDocument response;
  response["ok"] = false;
  if (!Update.canRollBack()) {
    response["error"] = "rollback image unavailable";
    writeJsonResponse(409, response);
    return;
  }
  if (!Update.rollBack()) {
    response["error"] = "rollback failed";
    writeJsonResponse(500, response);
    return;
  }
  response["ok"] = true;
  response["rolledBack"] = true;
  response["restarting"] = true;
  otaPersistState.lastStatus = "rolled-back-pending-reboot";
  otaPersistState.lastError = "";
  otaPersistState.lastAttemptAt = String(millis());
  saveOtaPersistState();
  scheduleRestart();
  writeJsonResponse(200, response);
}

void connectWiFi() {
  const String ssid = effectiveSsid();
  const String password = effectivePassword();
  const String hostname = effectiveHostname();

  WiFi.mode(WIFI_STA);
  WiFi.setHostname(hostname.c_str());
  if (ssid.length() == 0) {
    WiFi.mode(WIFI_AP);
    WiFi.softAP(kSetupApSsid);
    Serial.printf("Started setup AP: %s at %s\n", kSetupApSsid, WiFi.softAPIP().toString().c_str());
    return;
  }

  WiFi.begin(ssid.c_str(), password.c_str());
  Serial.printf("Connecting to WiFi SSID %s as %s.local\n", ssid.c_str(), hostname.c_str());

  const unsigned long start = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - start < 20000) {
    delay(300);
    Serial.print(".");
  }
  Serial.println();

  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("WiFi connect failed, falling back to AP mode");
    WiFi.disconnect(true, true);
    WiFi.mode(WIFI_AP);
    WiFi.softAP(kSetupApSsid);
    Serial.printf("Started setup AP: %s at %s\n", kSetupApSsid, WiFi.softAPIP().toString().c_str());
  }
}

void startMdns() {
  if (!isStationConnected()) {
    return;
  }
  if (MDNS.begin(effectiveHostname().c_str())) {
    MDNS.addService("bedjet-bridge", "tcp", kHttpPort);
    mdnsStarted = true;
    Serial.printf("mDNS ready: http://%s.local/\n", effectiveHostname().c_str());
  } else {
    Serial.println("mDNS failed to start");
  }
}

void registerRoutes() {
  server.on("/", HTTP_GET, []() {
    if (isStationConnected()) {
      handleGatewayPage();
      return;
    }
    handleProvisionPage();
  });
  server.on("/healthz", HTTP_GET, handleHealthz);
  server.on("/api/v1/version", HTTP_GET, handleVersion);
  server.on("/api/v1/provision/status", HTTP_GET, handleProvisionStatus);
  server.on("/api/v1/provision/wifi", HTTP_POST, []() {
    if (provisioningRequiresAuth() && !verifyRequestAuth()) {
      return;
    }
    handleProvisionSave();
  });
  server.on("/api/v1/claim/status", HTTP_GET, handleClaimStatus);
  server.on("/api/v1/claim", HTTP_POST, handleClaim);
  server.on("/api/v1/local/status", HTTP_GET, handleLocalStatus);
  server.on("/api/v1/local/scan", HTTP_GET, handleScan);
  server.on("/api/v1/local/settings", HTTP_POST, handleLocalSettings);
  server.on("/api/v1/local/release-all", HTTP_POST, handleReleaseAll);
  server.on("/api/v1/state", HTTP_GET, []() {
    if (!verifyRequestAuth()) {
      return;
    }
    handleState();
  });
  server.on("/api/v1/scan", HTTP_GET, []() {
    if (!verifyRequestAuth()) {
      return;
    }
    handleScan();
  });
  server.on("/api/v1/release-all", HTTP_POST, []() {
    if (!verifyRequestAuth()) {
      return;
    }
    handleReleaseAll();
  });
  server.on("/api/v1/firmware/update", HTTP_POST, handleFirmwareUpdate, handleFirmwareUploadChunk);
  server.on("/api/v1/firmware/rollback", HTTP_POST, []() {
    if (!verifyRequestAuth()) {
      return;
    }
    handleFirmwareRollback();
  });
  server.onNotFound([]() {
    const String uri = server.uri();
    if (requestRequiresAuth() && !verifyRequestAuth()) {
      return;
    }
    if (server.method() == HTTP_POST &&
        (uri.startsWith("/api/v1/pair/") || uri.startsWith("/api/v1/local/pair/"))) {
      handlePair();
      return;
    }
    if (server.method() == HTTP_POST &&
        (uri.startsWith("/api/v1/verify/") || uri.startsWith("/api/v1/local/verify/"))) {
      handleVerify();
      return;
    }
    if (server.method() == HTTP_POST &&
        (uri.startsWith("/api/v1/forget/") || uri.startsWith("/api/v1/local/forget/"))) {
      handleForget();
      return;
    }
    if (server.method() == HTTP_POST &&
        (uri.startsWith("/api/v1/release/") || uri.startsWith("/api/v1/local/release/"))) {
      handleRelease();
      return;
    }
    if (server.method() == HTTP_POST &&
        (uri.startsWith("/api/v1/command/") || uri.startsWith("/api/v1/local/command/"))) {
      handleCommand();
      return;
    }

    server.send(404, "application/json", "{\"error\":\"not found\"}");
  });
}

}  // namespace

void setup() {
  Serial.begin(115200);
  delay(200);
  preferences.begin(kPreferenceNamespace, false);
  BLEDevice::init("bedjet-gateway");
  bleScan = BLEDevice::getScan();
  bleScan->setActiveScan(true);
  bleScan->setInterval(160);
  bleScan->setWindow(80);
  const char *headerKeys[] = {"X-Gateway-Id", "X-Timestamp", "X-Nonce", "X-Signature", "X-Firmware-SHA256"};
  server.collectHeaders(headerKeys, 5);

  leftState.slot.side = "left";
  rightState.slot.side = "right";
  loadSlot(leftState.slot, "left");
  loadSlot(rightState.slot, "right");
  loadAuthState();
  loadWiFiConfig();
  loadActivityLightConfig();
  loadSmartThingsConfig();
  loadOtaPersistState();
  otaPersistState.bootCount += 1;
  if (otaPersistState.lastStatus == "applied-pending-reboot") {
    otaPersistState.lastStatus = "applied";
  } else if (otaPersistState.lastStatus == "rolled-back-pending-reboot") {
    otaPersistState.lastStatus = "rolled-back";
  }
  saveOtaPersistState();

  connectWiFi();
  startMdns();
  registerRoutes();
  server.begin();
  clearActivityLight();

  Serial.printf("HTTP server ready on port %u, mode=%s\n", kHttpPort, networkMode().c_str());
}

void loop() {
  server.handleClient();
  tickActivityLight();
  if (restartScheduled && millis() >= restartAtMs) {
    ESP.restart();
  }
  delay(2);
}
