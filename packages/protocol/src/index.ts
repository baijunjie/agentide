export const PROTOCOL_VERSION = 1 as const;

export const MESSAGE_NAMESPACES = [
  "system",
  "pairing",
  "project",
  "file",
  "session",
  "agent",
  "interaction",
] as const;

export type ProtocolVersion = typeof PROTOCOL_VERSION;
export type MessageNamespace = (typeof MESSAGE_NAMESPACES)[number];
export type MessageType = `${MessageNamespace}.${string}`;

export interface ProtocolError {
  code: string;
  message: string;
  details?: unknown;
}

export interface EncryptedPayload {
  encryptionVersion: 1;
  ciphertext: string;
}

export type WirePayload<T> = T | EncryptedPayload;

export interface EnvelopeMetadata {
  version: ProtocolVersion;
  id: string;
  type: MessageType;
  sourceDeviceId: string;
  targetDeviceId?: string;
  projectId?: string;
  sessionId?: string;
  timestamp: string;
}

export interface Envelope<T = unknown> extends EnvelopeMetadata {
  payload: WirePayload<T>;
}

export type RequestEnvelope<T = unknown> = Envelope<T>;

export interface ResponseEnvelope<T = unknown> extends EnvelopeMetadata {
  replyTo: string;
  ok: boolean;
  payload?: WirePayload<T>;
  error?: ProtocolError;
}

export function isMessageType(value: string): value is MessageType {
  return /^(system|pairing|project|file|session|agent|interaction)\.[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*$/.test(
    value,
  );
}

export function isEncryptedPayload(value: unknown): value is EncryptedPayload {
  if (!isRecord(value)) {
    return false;
  }

  return (
    hasOnlyKeys(value, ["encryptionVersion", "ciphertext"]) &&
    value.encryptionVersion === 1 &&
    typeof value.ciphertext === "string"
  );
}

export function isEnvelope(value: unknown): value is Envelope | ResponseEnvelope {
  if (!isRecord(value)) {
    return false;
  }

  const isMetadataValid =
    value.version === PROTOCOL_VERSION &&
    isNonEmptyString(value.id) &&
    typeof value.type === "string" &&
    isMessageType(value.type) &&
    isNonEmptyString(value.sourceDeviceId) &&
    optionalString(value.targetDeviceId) &&
    optionalString(value.projectId) &&
    optionalString(value.sessionId) &&
    isProtocolTimestamp(value.timestamp);

  if (!isMetadataValid) {
    return false;
  }

  const response = "replyTo" in value || "ok" in value || "error" in value;
  if (response) {
    return (
      hasOnlyKeys(value, RESPONSE_KEYS) &&
      isNonEmptyString(value.replyTo) &&
      typeof value.ok === "boolean" &&
      (value.error === undefined || isProtocolError(value.error)) &&
      (value.payload === undefined || isValidWirePayload(value.payload))
    );
  }

  return hasOnlyKeys(value, REQUEST_KEYS) && "payload" in value && isValidWirePayload(value.payload);
}

function optionalString(value: unknown): boolean {
  return value === undefined || isNonEmptyString(value);
}

function isNonEmptyString(value: unknown): value is string {
  return typeof value === "string" && value.length > 0;
}

export function isProtocolTimestamp(value: unknown): value is string {
  if (typeof value !== "string") {
    return false;
  }

  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?Z$/.exec(value);
  if (match === null) {
    return false;
  }

  const [, yearText, monthText, dayText, hourText, minuteText, secondText] = match;
  const year = Number(yearText);
  const month = Number(monthText);
  const day = Number(dayText);
  const hour = Number(hourText);
  const minute = Number(minuteText);
  const second = Number(secondText);
  const daysInMonth = [31, isLeapYear(year) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];

  return (
    month >= 1 &&
    month <= 12 &&
    day >= 1 &&
    day <= (daysInMonth[month - 1] ?? 0) &&
    hour <= 23 &&
    minute <= 59 &&
    second <= 59
  );
}

function isLeapYear(year: number): boolean {
  return year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
}

function isValidWirePayload(value: unknown): boolean {
  if (isRecord(value) && ("encryptionVersion" in value || "ciphertext" in value)) {
    return isEncryptedPayload(value);
  }
  return true;
}

function isProtocolError(value: unknown): value is ProtocolError {
  return (
    isRecord(value) &&
    hasOnlyKeys(value, ["code", "message", "details"]) &&
    isNonEmptyString(value.code) &&
    isNonEmptyString(value.message)
  );
}

function hasOnlyKeys(value: Record<string, unknown>, allowed: readonly string[]): boolean {
  return Object.keys(value).every((key) => allowed.includes(key));
}

const METADATA_KEYS = [
  "version",
  "id",
  "type",
  "sourceDeviceId",
  "targetDeviceId",
  "projectId",
  "sessionId",
  "timestamp",
] as const;
const REQUEST_KEYS = [...METADATA_KEYS, "payload"] as const;
const RESPONSE_KEYS = [...METADATA_KEYS, "payload", "replyTo", "ok", "error"] as const;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
