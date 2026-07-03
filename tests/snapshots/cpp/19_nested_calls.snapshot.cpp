
namespace {

BallDyn triple(int64_t x);
BallDyn addOne(int64_t x);
BallDyn pipeline(int64_t x);

BallDyn triple(int64_t x) {
    auto& input = x;
    return (x * static_cast<int64_t>(3));
    return BallDyn();
}

BallDyn addOne(int64_t x) {
    auto& input = x;
    return (x + static_cast<int64_t>(1));
    return BallDyn();
}

BallDyn pipeline(int64_t x) {
    auto& input = x;
    return triple(addOne(triple(x)));
    return BallDyn();
}

} // namespace

int main() {
    std::cout << ball_to_string(ball_to_string(pipeline(static_cast<int64_t>(2)))) << std::endl;
    std::cout << ball_to_string(ball_to_string(pipeline(static_cast<int64_t>(0)))) << std::endl;
    std::cout << ball_to_string(ball_to_string(triple(triple(triple(static_cast<int64_t>(1)))))) << std::endl;
    return 0;
}
