import SwiftUI

struct CourseMetadataView: View {
    let course: Course
    var showsMissingClassroom = false
    private var teacher: String { course.teacher.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 15) {
            if let classroom = course.classroom {
                Label(classroom, systemImage: "mappin.and.ellipse")
                    .accessibilityLabel("上课教室：\(classroom)")
            } else if showsMissingClassroom {
                Label("教室暂未提供", systemImage: "mappin.and.ellipse")
            }
            if !teacher.isEmpty {
                Label(teacher, systemImage: "person")
                    .accessibilityLabel("授课教师：\(teacher)")
            } else if course.classroom == nil && !showsMissingClassroom {
                Text("课程详情")
            }
        }
        .labelStyle(CourseMetadataLabelStyle())
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct CourseMetadataLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}
