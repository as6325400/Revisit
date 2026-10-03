import SwiftUI

struct WorkoutRow: View {
    let record: WorkoutRecord

    var body: some View {
        HStack(spacing: 14) {
            RouteThumbnail(
                workoutID: record.workoutID,
                coordinates: record.previewCoordinates,
                status: record.routeStatus,
                fallbackSymbol: record.hasNoRouteByNature ? record.kind.symbolName : nil
            )
            .frame(width: 76, height: 76)

            VStack(alignment: .leading, spacing: 4) {
                Label(record.displayName, systemImage: record.kind.symbolName)
                    .font(.headline)
                Text(record.startDate.formatted(.dateTime.month().day().weekday(.abbreviated).hour().minute()))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Text(Formatters.distance(record.distance)).fontWeight(.semibold)
                    Text(Formatters.duration(record.duration))
                    Text(Formatters.pace(distance: record.distance, duration: record.duration, style: record.kind.paceStyle))
                }
                .font(.subheadline)
                .monospacedDigit()
            }
        }
        .padding(.vertical, 4)
    }
}
