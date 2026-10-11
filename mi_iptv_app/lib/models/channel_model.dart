class ChannelModel {
  final String id;
  final String name;
  final String streamUrl;
  final String logoUrl;
  final String groupCategory;
  final bool isValid;

  ChannelModel({
    required this.id,
    required this.name,
    required this.streamUrl,
    required this.logoUrl,
    required this.groupCategory,
    this.isValid = true,
  });
}
