// 공용 헬퍼 — 각 섹션에서 #import "../helpers.typ": * 로 사용
#let figbox(path, caption, w: 80%) = figure(
  image(path, width: w),
  caption: caption,
)
#let placeholder(label, h: 3cm) = figure(
  rect(width: 80%, height: h, fill: luma(238), stroke: (dash: "dashed"))[
    #align(center + horizon)[#text(fill: luma(120))[[자산 준비 예정] #label]]
  ],
  caption: label,
)
