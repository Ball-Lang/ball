
namespace {

BallDyn abs_(int64_t x);
BallDyn sign(int64_t x);

BallDyn abs_(int64_t x) {
    auto& input = x;
    return (BallDyn((x < static_cast<int64_t>(0)) ? BallDyn((-x)) : BallDyn(x)));
    return BallDyn();
}

BallDyn sign(int64_t x) {
    auto& input = x;
    return (BallDyn((x > static_cast<int64_t>(0)) ? BallDyn("pos"s) : BallDyn(((BallDyn((x < static_cast<int64_t>(0)) ? BallDyn("neg"s) : BallDyn("zero"s)))))));
    return BallDyn();
}

} // namespace

int main() {
    std::cout << ball_to_string(ball_to_string(abs_((-static_cast<int64_t>(5))))) << std::endl;
    std::cout << ball_to_string(ball_to_string(abs_(static_cast<int64_t>(7)))) << std::endl;
    std::cout << ball_to_string(sign(static_cast<int64_t>(3))) << std::endl;
    std::cout << ball_to_string(sign((-static_cast<int64_t>(3)))) << std::endl;
    std::cout << ball_to_string(sign(static_cast<int64_t>(0))) << std::endl;
    return 0;
}
