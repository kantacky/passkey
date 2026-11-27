type SignalCapablePublicKeyCredential = typeof PublicKeyCredential & {
  getClientCapabilities?: () => Promise<Record<string, boolean>>;
  signalUnknownCredential?: (options: {
    rpId: string;
    credentialId: string;
  }) => Promise<void>;
  signalAllAcceptedCredentials?: (options: {
    rpId: string;
    userId: string;
    allAcceptedCredentialIds: string[];
  }) => Promise<void>;
  signalCurrentUserDetails?: (options: {
    rpId: string;
    userId: string;
    name: string;
    displayName: string;
  }) => Promise<void>;
};

type SignalCapability =
  | "signalUnknownCredential"
  | "signalAllAcceptedCredentials"
  | "signalCurrentUserDetails";

function signalApi(): SignalCapablePublicKeyCredential | null {
  if (
    typeof window === "undefined" ||
    typeof window.PublicKeyCredential === "undefined"
  )
    return null;
  return window.PublicKeyCredential as SignalCapablePublicKeyCredential;
}

export async function getClientCapabilities(): Promise<Record<
  string,
  boolean
> | null> {
  const ctor = signalApi();
  if (!ctor?.getClientCapabilities) return null;
  try {
    return await ctor.getClientCapabilities();
  } catch {
    return null;
  }
}

async function supportsSignal(capability: SignalCapability): Promise<boolean> {
  const ctor = signalApi();
  if (!ctor?.[capability]) return false;
  const capabilities = await getClientCapabilities();
  if (!capabilities) return true;
  return capabilities[capability] === true;
}

export function getRpId(): string {
  return window.location.hostname;
}

export async function signalUnknownCredential(
  credentialId: string,
): Promise<boolean> {
  const ctor = signalApi();
  if (
    !ctor?.signalUnknownCredential ||
    !(await supportsSignal("signalUnknownCredential"))
  )
    return false;
  try {
    await ctor.signalUnknownCredential({ rpId: getRpId(), credentialId });
    return true;
  } catch {
    return false;
  }
}

export async function signalAllAcceptedCredentials(
  userId: string,
  allAcceptedCredentialIds: string[],
): Promise<boolean> {
  const ctor = signalApi();
  if (
    !ctor?.signalAllAcceptedCredentials ||
    !(await supportsSignal("signalAllAcceptedCredentials"))
  )
    return false;
  try {
    await ctor.signalAllAcceptedCredentials({
      rpId: getRpId(),
      userId,
      allAcceptedCredentialIds,
    });
    return true;
  } catch {
    return false;
  }
}

export async function signalCurrentUserDetails(
  userId: string,
  email: string,
): Promise<boolean> {
  const ctor = signalApi();
  if (
    !ctor?.signalCurrentUserDetails ||
    !(await supportsSignal("signalCurrentUserDetails"))
  )
    return false;
  try {
    await ctor.signalCurrentUserDetails({
      rpId: getRpId(),
      userId,
      name: email,
      displayName: email,
    });
    return true;
  } catch {
    return false;
  }
}
