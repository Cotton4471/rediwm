// Read the platform plugin's real QPalette, including the Qt6 Accent role.
#include <QApplication>
#include <QPalette>
#include <QJsonDocument>
#include <QJsonObject>
#include <cstdio>

int main(int argc, char **argv) {
    QApplication app(argc, argv);
    QPalette p = app.palette();
    QJsonObject out{
        {"bg", p.color(QPalette::Window).name()},
        {"fg", p.color(QPalette::WindowText).name()},
        {"accent", p.color(QPalette::Highlight).name()},
        {"on_accent", p.color(QPalette::HighlightedText).name()},
        {"disabled", p.color(QPalette::Disabled, QPalette::WindowText).name()}
    };
#if QT_VERSION >= QT_VERSION_CHECK(6, 6, 0)
    out.insert("qt6_accent", p.color(QPalette::Accent).name());
#endif
    std::puts(QJsonDocument(out).toJson(QJsonDocument::Compact).constData());
}
