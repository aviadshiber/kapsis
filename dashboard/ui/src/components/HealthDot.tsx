import type { HealthState } from "../types";

interface Props {
  state: HealthState;
  title?: string;
}

export function HealthDot({ state, title }: Props) {
  return <span className={`health-dot ${state}`} title={title ?? state} />;
}
