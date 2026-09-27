export interface CompanionConfiguration {
  port: number;
  authenticationToken: string;
  parentProcessId: number;
}

export function consumeCompanionConfiguration(environment: NodeJS.ProcessEnv): CompanionConfiguration {
  const portValue = environment.AGENT_HOST_PORT ?? "0";
  const authenticationToken = environment.AGENT_HOST_TOKEN;
  const parentProcessIdValue = environment.AGENT_HOST_PARENT_PID;
  delete environment.AGENT_HOST_PORT;
  delete environment.AGENT_HOST_TOKEN;
  delete environment.AGENT_HOST_PARENT_PID;

  if (!/^\d+$/.test(portValue)) throw new Error("AGENT_HOST_PORT must be an integer from 0 through 65535");
  const port = Number(portValue);
  if (!Number.isInteger(port) || port < 0 || port > 65_535) {
    throw new Error("AGENT_HOST_PORT must be an integer from 0 through 65535");
  }
  if (authenticationToken === undefined || authenticationToken.length < 32) {
    throw new Error("AGENT_HOST_TOKEN must contain at least 32 characters");
  }
  if (parentProcessIdValue === undefined || !/^\d+$/.test(parentProcessIdValue)) {
    throw new Error("AGENT_HOST_PARENT_PID must identify the supervising process");
  }
  const parentProcessId = Number(parentProcessIdValue);
  if (!Number.isSafeInteger(parentProcessId) || parentProcessId <= 1) {
    throw new Error("AGENT_HOST_PARENT_PID must identify the supervising process");
  }
  return { port, authenticationToken, parentProcessId };
}
