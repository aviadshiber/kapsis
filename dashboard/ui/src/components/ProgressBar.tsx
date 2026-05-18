interface Props {
  value: number;
}

export function ProgressBar({ value }: Props) {
  const clamped = Math.max(0, Math.min(100, value));
  return (
    <div className="progress-bar" aria-valuemin={0} aria-valuemax={100} aria-valuenow={clamped} role="progressbar">
      <div style={{ width: `${clamped}%` }} />
    </div>
  );
}
